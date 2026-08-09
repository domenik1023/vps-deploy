# Ansible Playbook for VPS Hardening

## Description

Hardens a fresh Ubuntu VPS with:

- SSH key-only authentication on a custom port (22822), with port 22 denied after hardening
- UFW firewall with connection-rate limiting on the SSH port
- Fail2ban as a local backstop behind CrowdSec (bans after 15 failed attempts)
- CrowdSec agent (log processor) reporting to a central LAPI server, with firewall bouncer pulling shared ban decisions
- Grafana Alloy telemetry agent pushing metrics, logs, traces and profiles to the central observability stack
- Root account locked (no password, no login shell)
- Kernel hardening via sysctl (SYN cookies, ASLR, ICMP filtering, anti-spoofing)
- Docker Engine with security daemon config (log rotation, live-restore, no-new-privileges; optional user namespace remap)
- Chrony NTP for accurate system time
- Daily unattended security upgrades, with a weekly reboot window for updates that need one

## Project Structure

```
vps-deploy/
├── main.yml                          # Entry point
├── inventory                         # Host names, grouped (vps / local / lapi)
├── ansible.cfg                       # Ansible settings
├── requirements.yml                  # Galaxy collections
├── CLAUDE.md                         # Orientation for Claude Code
├── .ansible-lint                     # Lint profile and the two skipped rules
├── .github/workflows/ci.yml          # syntax check, lint, render check
├── tests/
│   └── render-check.yml              # Variable shapes and design invariants
├── group_vars/
│   ├── all/
│   │   └── vault.yml                 # Encrypted secrets (ansible-vault)
│   └── vps.yml                       # Off-site hosts: the public ingest hostname
├── docs/
│   ├── crowdsec.md                   # CrowdSec architecture, log sources, troubleshooting
│   └── alloy.md                      # Alloy pipelines, ingest hostnames, troubleshooting
├── host_vars/                        # Optional per-host settings, by name
│   ├── vps-docker.yml                # Address, SSH port, per-host overrides
│   ├── vps-pangolin.yml
│   ├── testvm.yml
│   └── crowdsec-master.yml           # Central LAPI (delegation target only)
└── roles/
    ├── config/
    │   ├── defaults/
    │   │   └── main.yml              # All configurable variables
    │   ├── handlers/
    │   │   └── main.yml              # Service restart handlers
    │   └── tasks/
    │       ├── main.yml              # Task orchestration
    │       ├── hostname.yml          # System hostname = inventory name
    │       ├── user.yml              # Admin user + sudo setup
    │       ├── hardening.yml         # SSH, UFW, Fail2ban, root lockdown
    │       ├── sysctl.yml            # Kernel parameter hardening
    │       ├── software.yml          # Docker, NTP, auto-updates
    │       ├── crowdsec.yml          # CrowdSec agent + firewall bouncer
    │       └── crowdsec_credentials.yml  # Automatic LAPI machine/bouncer provisioning
    └── alloy/
        ├── defaults/
        │   └── main.yml              # Pipelines, endpoints, bind addresses, version pin
        ├── templates/
        │   └── config.alloy.j2       # Rendered to /etc/alloy/config.alloy
        └── tasks/
            └── main.yml              # Prerequisite asserts + grafana.grafana.alloy
```

## Prerequisites

1. Target host is running Ubuntu (tested on 22.04/24.04/26.04)
2. SSH access as root (or a user with sudo) is available on port 22 for the initial run
3. Your public key is present in `~/.ssh/domenik1023.pub` (or adjust the private key path below)
4. Python 3 is installed on the target host
5. Ansible collections installed locally:
   ```bash
   ansible-galaxy collection install -r requirements.yml
   ```

## Secrets Setup (Ansible Vault)

The admin user password is stored in `group_vars/all/vault.yml` and **must be encrypted** before committing. It is the only secret kept there — CrowdSec's credentials are created at deploy time, see below.

1. Generate a sha512-crypt password hash:
   ```bash
   python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('yourpassword'))"
   ```

2. Edit the vault file and set the hash:
   ```bash
   ansible-vault edit group_vars/all/vault.yml
   ```
   Set `vault_admin_password` to the hash generated above.

3. On first use, encrypt the file if it is still plaintext:
   ```bash
   ansible-vault encrypt group_vars/all/vault.yml
   ```

## CrowdSec Credentials

> Adding a log source (a Caddy container, an nginx file), verifying parsing and
> troubleshooting bans are covered in **[docs/crowdsec.md](docs/crowdsec.md)**.
> Out of the box CrowdSec watches sshd and the firewall's own drop logs;
> application traffic needs a source adding.

CrowdSec is installed on internet-facing hosts only: the `[local]` group is
skipped, the same way SSH hardening skips it. Local hosts sit behind NAT and
see none of the traffic CrowdSec exists to catch, and each would still consume
a machine registration and a bouncer key on the central LAPI.

Each agent needs two secrets from the central LAPI server: a machine
login/password and a firewall bouncer API key. Both are created for you — point
`crowdsec_lapi_host` at the inventory host running the LAPI and the playbook
mints them by running `cscli` there over Ansible delegation:

```yaml
# group_vars/all/main.yml, or per-host in the inventory
crowdsec_lapi_url: "https://lapi.internal:8080"
crowdsec_lapi_host: "lapi.internal"     # must be reachable in the inventory
```

If the LAPI runs in a Docker container, name it and `cscli` is invoked inside
the container instead of on the host:

```yaml
crowdsec_lapi_docker_container: "crowdsec"
```

For anything else (podman, `docker compose exec`, a wrapper script) override the
invocation prefix directly — it is a plain argument list:

```yaml
crowdsec_lapi_cscli: ["docker", "compose", "-f", "/srv/crowdsec/compose.yml", "exec", "-T", "crowdsec", "cscli"]
```

Requirements: the LAPI host is in the inventory, reachable over SSH, and the
connecting user can `become` root there (enough to run `docker exec` in the
container case). Put it in the inventory's `[lapi]` group — `main.yml` runs
against `all:!lapi`, so the master is used purely as a delegation target and is
not reconfigured as an agent, which would disable the very LAPI the fleet
depends on.

`crowdsec_lapi_host` is required; the run stops with a clear message if it is
unset, rather than writing a config the agent cannot authenticate with.

No CrowdSec secret goes into the vault — the generated ones live only in
`/etc/crowdsec/local_api_credentials.yaml` and
`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml.local` on the agent, and
hashed in the LAPI database.

Re-runs are idempotent. Before touching anything the playbook verifies what the
agent already has — `cscli lapi status` for the machine credentials, an
authenticated `GET /v1/decisions` for the bouncer key — and reuses working
secrets verbatim. A secret is only rotated when it is missing, points at a
different LAPI, or is rejected. Re-registering an agent whose credentials were
lost works too: the machine is re-added with `--force` and a stale bouncer of
the same name is deleted first.

Provisioning goes through `cscli` rather than HTTP because the LAPI's REST API
cannot do the job: it can register a machine (`POST /v1/watchers`) only when
auto-registration is enabled on the server, and it has no endpoint at all for
creating a bouncer — bouncer keys exist only in the LAPI database.

## Grafana Alloy

> The pipelines, the two ingest hostnames, adding a log source, eBPF
> prerequisites and troubleshooting are covered in
> **[docs/alloy.md](docs/alloy.md)**.

Every host gets one Alloy agent, installed natively from the upstream release
(deb + systemd) by `grafana.grafana.alloy`, and configured from
`roles/alloy/templates/config.alloy.j2`. It collects host and container metrics,
the journal, container stdout, OTLP traces and Pyroscope profiles, and **pushes**
them all to one ingest hostname.

Two hostnames reach the same reverse proxy and the same backends; only the
network path differs. `https://ingest.net.d1023.de` is LAN-routed and is the
default, so a host on 192.168.2.x needs no configuration. Off-site hosts are
switched a whole group at a time — `group_vars/vps.yml` is the entire override:

```yaml
alloy_ingest_base: "https://ingest.d1023.de"
```

All four signal endpoints derive from that value. `head -3
/etc/alloy/config.alloy` on a host says which one it actually got.

Per-host settings go in `host_vars/<name>.yml`:

```yaml
# A host with no Docker and nothing worth profiling
alloy_enable_docker: false
alloy_enable_profiles: false

# An application writing logs to disk rather than stdout
alloy_extra_log_paths:
  - { path: "/tmp/pangolin/*.log", job: "pangolin" }

# The one host where whole-host eBPF profiling is wanted
alloy_enable_ebpf: true
```

Two things are deliberate and easy to undo by accident. The OTLP receiver, the
profile receiver and the Alloy UI are all **unauthenticated** and all stay on
loopback — reach the UI with `ssh -L 12345:localhost:12345 <host>` rather than
opening the port, and note that no UFW rule is added for any of them, because
`ufw reload` flushes the CrowdSec bouncer's chains. And `alloy_agent_version` is
**pinned**: upstream's default of `latest` queries the GitHub API on every run
and can upgrade a host unasked. Both are asserted in `tests/render-check.yml`.

The ingest endpoints are unauthenticated by design — agents cannot do
interactive OIDC. Do not add credentials to the agent config expecting the
server to check them.

## Inventory and Host Variables

`inventory` lists host *names* and their groups. A name that resolves — via
DNS, `/etc/hosts` or an SSH config alias — needs nothing further. Anything
host-specific otherwise (address, SSH port, per-host overrides) goes in
`host_vars/<name>.yml`:

```ini
[vps]
vps-pangolin
vps-docker
```

```yaml
# host_vars/vps-pangolin.yml — only if the name does not resolve on its own
ansible_host: 203.0.113.10
ansible_port: 22          # 22822 once hardening has run
```

Names are not cosmetic. `crowdsec_lapi_login` and `crowdsec_bouncer_name` both
derive from `inventory_hostname`, so the name is what the host registers as on
the central LAPI — `vps-docker` and `vps-docker-firewall-bouncer` rather than
a bare IP. The playbook also sets the **system hostname** to the inventory name,
because Alloy labels every metric, log line and profile with `instance` taken
from the host's own name — a box called `pangolin` locally but `vps-pangolin`
here ships telemetry that no query filtering on the inventory name will find.
Renaming a host that is already reporting splits its history: old series and log
streams stay under the previous label.
Renaming a host that is already registered makes it register again under the
new name; delete the leftovers on the master with `cscli machines delete` and
`cscli bouncers delete`.

## Configuration

Hardening, Docker and CrowdSec values live in `roles/config/defaults/main.yml`;
Alloy's live in `roles/alloy/defaults/main.yml` and are tabled
[below](#grafana-alloy-1).

| Variable | Default | Description |
|---|---|---|
| `system_hostname` | `{{ inventory_hostname }}` | System hostname to set. Alloy's `instance` label comes from it, so a mismatch with the inventory name hides that host's telemetry |
| `system_hostname_manage` | `true` | Set `false` to leave the host's own name alone |
| `system_hostname_pattern` | RFC 1123 regex | Validates the name before it is written; underscores are legal in an inventory name but not in a hostname |
| `admin_user` | `domenik1023` | Admin username to create |
| `admin_password` | `{{ vault_admin_password }}` | sha512-crypt hash (from vault) |
| `ssh_port` | `22822` | Custom SSH port |
| `ssh_old_port` | `22` | Standard port to deny after hardening |
| `fail2ban_maxretry` | `15` | Failed attempts before ban — set above CrowdSec's SSH thresholds so it bans first |
| `fail2ban_findtime` | `10m` | Time window for failed attempts |
| `fail2ban_bantime` | `1h` | How long IPs stay banned |
| `unattended_reboot_enabled` | `true` | Enable the weekly reboot timer for pending upgrades |
| `unattended_reboot_oncalendar` | `Sat *-*-* 05:00:00` | systemd `OnCalendar` for the reboot window |
| `docker_data_dir` | `/mnt/docker` | Directory for persistent volume data (created only; not Docker's data root) |
| `docker_daemon_options` | log rotation, live-restore, no-new-privileges | Contents of `/etc/docker/daemon.json` |
| `docker_userns_remap` | `""` (off) | Set to `"default"` for user namespace remapping — see the note below |
| `crowdsec_collections` | `[crowdsecurity/linux, crowdsecurity/iptables]` | Base collections every agent gets |
| `crowdsec_collections_extra` | `[]` | Per-host additions — add here rather than replacing the base list |
| `ufw_logging` | `low` | UFW log level; the port-scan scenario reads these drop lines |
| `crowdsec_acquisitions` | `{}` | Extra log sources per host — see [docs/crowdsec.md](docs/crowdsec.md) |
| `crowdsec_firewall_bouncer_package` | `crowdsec-firewall-bouncer-iptables` | Bouncer package (`-nftables` variant for pure-nftables hosts) |
| `crowdsec_firewall_bouncer_service` | `crowdsec-firewall-bouncer` | Systemd unit; both packages ship the same one |
| `crowdsec_firewall_bouncer_mode` | derived from the package | Backend pinned in the `.local` overlay, so a base config still holding `${BACKEND}` cannot stop the bouncer |
| `crowdsec_lapi_url` | `https://crowdsec.d1023.de` | Central LAPI server URL (override per environment) |
| `crowdsec_lapi_login` | `{{ inventory_hostname }}` | Machine login on the central LAPI |
| `crowdsec_bouncer_name` | `{{ inventory_hostname }}-firewall-bouncer` | Bouncer name on the central LAPI |
| `crowdsec_bouncer_iptables_chains` | `[INPUT]` | Chains bans are enforced in, for IPv4 **and** IPv6 — must exist in both |
| `crowdsec_bouncer_iptables_v4_chains` | `[DOCKER-USER]` | IPv4-only chains; absent ones are dropped at run time |
| `crowdsec_lapi_host` | `crowdsec-master` | **Required.** Inventory host running the LAPI, used to provision credentials |
| `crowdsec_lapi_docker_container` | `crowdsec-master-crowdsec-1` | Container name, when the LAPI runs in Docker on that host |
| `crowdsec_lapi_cscli` | `["cscli"]` / `docker exec …` | `cscli` invocation prefix on the LAPI host; override for podman, compose, wrappers |
| `crowdsec_lapi_validate_certs` | `true` | Set to `false` if the LAPI serves a self-signed certificate |

### Grafana Alloy

From `roles/alloy/defaults/main.yml`. See [docs/alloy.md](docs/alloy.md) for what
each pipeline actually collects.

| Variable | Default | Description |
|---|---|---|
| `alloy_ingest_base` | `https://ingest.net.d1023.de` | LAN ingest hostname; `group_vars/vps.yml` switches off-site hosts to the public one. All four signal endpoints derive from it |
| `alloy_loki_endpoint` | derived + `/loki/api/v1/push` | Override only to send logs somewhere else |
| `alloy_prom_endpoint` | derived + `/api/v1/write` | Override only to send metrics somewhere else |
| `alloy_tempo_endpoint` | derived (base URL) | Base URL — the OTLP exporter appends `/v1/traces` itself |
| `alloy_pyroscope_endpoint` | derived (base URL) | Base URL — `pyroscope.write` appends `/push.v1.PusherService/Push` itself |
| `alloy_enable_docker` | `true` | cAdvisor metrics and container log discovery; **false on a host without Docker**, or the components log socket errors continuously |
| `alloy_enable_journal` | `true` | systemd journal; false on non-systemd hosts |
| `alloy_enable_otlp` | `true` | OTLP trace receiver on loopback |
| `alloy_enable_profiles` | `true` | Pyroscope SDK receiver on loopback, and the write output eBPF also needs |
| `alloy_enable_ebpf` | `false` | Whole-host eBPF profiling; requires root and a few kernel prerequisites |
| `alloy_extra_log_paths` | `[]` | Log files to tail, as `{ path, job }` mappings — a list, so the rendered config stays byte-stable |
| `alloy_extra_scrape_targets` | `[]` | Prometheus endpoints already on the host (Traefik, an app's `/metrics`), as `{ name, address }` mappings — see [docs/alloy.md](docs/alloy.md#scraping-something-that-already-exposes-metrics) |
| `alloy_otlp_bind` | `127.0.0.1` | Unauthenticated receiver; asserted to stay on loopback |
| `alloy_profiles_bind` | `127.0.0.1` | Unauthenticated receiver; asserted to stay on loopback |
| `alloy_ui_bind` | `127.0.0.1` | Alloy UI and `/metrics`; reach it over an SSH tunnel |
| `alloy_custom_args` | `--disable-reporting` | Extra `ExecStart` flags; adds `--server.http.listen-addr` only when the UI bind differs from Alloy's own default |
| `alloy_log_level` | `info` | Alloy's own log level |
| `alloy_scrape_interval` | `15s` | Applies to the node, self and cAdvisor scrapes |
| `alloy_cluster` | `homelab` | External label on every metric, log line and profile |
| `alloy_ebpf_interval` | `15s` | eBPF profile collection interval |
| `alloy_docker_host` | `unix:///var/run/docker.sock` | Docker socket used by cAdvisor and log discovery |
| `alloy_agent_version` | `1.18.1` | **Pinned.** Bumping this and re-running is the upgrade path; upstream's `latest` would query the GitHub API each run. Deliberately not called `alloy_version` — that name collides with the upstream role's own default |
| `alloy_service_user` | `root` | Written into the systemd override. Required for cAdvisor's cgroup reads, `/dev/kmsg` and eBPF |
| `alloy_service_extra_groups` | `[]` | Supplementary groups for the `alloy` user; only meaningful on the unprivileged path |

## Usage

### Initial run (port 22, root or sudo user)

```bash
ansible-playbook main.yml -i inventory \
  --private-key=~/.ssh/domenik1023 \
  --ask-vault-pass \
  -u root
```

### Subsequent runs (custom port, admin user)

After hardening, SSH is on port 22822 and root login is disabled:

```bash
ansible-playbook main.yml -i inventory \
  --private-key=~/.ssh/domenik1023 \
  --ask-vault-pass \
  -u domenik1023
```

Update `ansible_port` to `22822` in `host_vars/<name>.yml` for each VPS after its first run.

### Checks

The three commands CI runs, which need no target host:

```bash
ansible-playbook main.yml -i inventory --syntax-check
ansible-lint
ansible-playbook tests/render-check.yml
```

The render check exists because the other two happily accept a Jinja expression
that parses but evaluates to the wrong type — a list that becomes a string, a
dict that stops being valid JSON. It also pins the design decisions that are
easy to reverse by accident: fail2ban staying duller than CrowdSec, user
namespace remapping staying off, only both-family chains in
`crowdsec_bouncer_iptables_chains`, Alloy's three listeners staying on loopback,
and every Alloy signal endpoint still deriving from `alloy_ingest_base`.

It renders `config.alloy.j2` too, and asserts the toggles actually add and
remove the pipelines they name and that nothing reaches
`grafana.grafana.alloy`'s own templating pass still holding a Jinja delimiter —
a block that does would be evaluated away silently, leaving a config Alloy
starts perfectly happily without.

### Dry run (check mode)

```bash
ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 --ask-vault-pass --check
```

## Notes

- **Docker user namespace remapping is off by default.** It maps container root
  to an unprivileged host UID, which breaks any container that bind-mounts
  `/var/run/docker.sock` — the socket is `root:docker` and remapped root is
  neither, so container managers (Komodo Periphery, Portainer, Watchtower, a
  Traefik docker provider) fail with permission errors. It also relocates the
  data root to `/var/lib/docker/<subuid>.<subgid>/`, so turning it on or off
  hides every container, image and volume created under the other setting;
  the old data is still on disk under the other path. Enable it per host with
  `docker_userns_remap: "default"` only where nothing needs the socket.
- The `[local]` inventory group skips SSH hardening to prevent self-lockout during testing, and skips CrowdSec, which only belongs on internet-facing hosts
- CrowdSec bans are enforced in `INPUT` **and** `DOCKER-USER`. The bouncer's own default is `INPUT` alone, which misses traffic Docker forwards to published container ports — UFW and Fail2ban have that same blind spot, so on a container host they only protect services listening on the host itself. Container-to-container traffic crosses `DOCKER-USER` too but carries RFC1918 source addresses, which never appear in the ban list. `DOCKER-USER` is configured as an IPv4-only chain: `iptables_chains` applies to both families, and Docker creates that chain in ip6tables only when IPv6 is enabled for Docker — a chain the bouncer cannot find aborts its startup. Chains missing on a host are dropped at run time, and the unit gets a drop-in ordering it after `docker.service`.
- CrowdSec is installed from the official packagecloud repository and runs alongside Fail2ban; both can ban independently. CrowdSec reads sshd events directly from journald, so it works on minimal images without rsyslog.
- CrowdSec runs in **agent-only mode**: the local API server is disabled and the agent pushes alerts to the central LAPI server (`crowdsec_lapi_url`). The firewall bouncer pulls decisions from the same central LAPI, so bans made anywhere in the fleet apply on this host too. CAPI enrollment/console registration happens on the central LAPI server, not on the agents.
- `host_key_checking` is disabled in `ansible.cfg` for the initial connection; use `ssh-keyscan` to pre-populate `known_hosts` in production environments

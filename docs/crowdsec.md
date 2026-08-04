# CrowdSec

How CrowdSec is wired on these hosts, and how to teach it about a service it
does not watch yet — a Caddy container, an nginx log file, another unit.

For the initial credential setup, see
[CrowdSec Credentials](../README.md#crowdsec-credentials) in the main README.

## How it fits together

Each VPS runs CrowdSec as a **log processor only**. It reads logs, parses them,
matches them against scenarios, and ships the resulting alerts to a central
LAPI server. It keeps no decisions of its own — the local API server is turned
off in `/etc/crowdsec/config.yaml.local`.

```
  vps-docker                          crowdsec-master
  ┌──────────────────────────┐        ┌───────────────────────┐
  │ logs ─► agent ─► alerts ─┼───────►│ LAPI (Docker)         │
  │                          │        │  decides + stores     │
  │ firewall bouncer ◄───────┼────────┼─ decisions            │
  │  drops in INPUT          │        └───────────────────────┘
  │  and DOCKER-USER         │              ▲
  └──────────────────────────┘              │
                                     other agents' alerts
```

Because every agent reports to the same LAPI, a ban earned on one host applies
on all of them. Parsers and scenarios still run locally, which is why
collections are installed on each agent even in this mode.

## What is watched out of the box

Two sources, on every agent:

- **sshd**, read from the journal (`_SYSTEMD_UNIT=ssh.service`)
- **firewall drops**, read from the kernel log (`_TRANSPORT=kernel`), which is
  where UFW records blocked packets

Between them that covers authentication against sshd and connection attempts to
every other port — including ones nothing listens on, which is the only signal
here that is not tied to a specific service. `crowdsecurity/iptables-scan-multi_ports`
needs **16 distinct destination ports** from one IP inside roughly a minute, so
routine single-port probing is ignored and only real sweeps register.

The kernel filter matches by journal field, not content, so unrelated kernel
messages are read and left unparsed. Expect a gap between `lines_read` and
`lines_parsed` for that source in `cscli metrics`; it is not a fault.

Application traffic is **not** covered by either. CrowdSec parses only what it
is pointed at, so a host serving HTTP needs its own source — see below.

## Collections

`crowdsec_collections` in the role defaults is the floor every agent gets.
Per-host additions go in `crowdsec_collections_extra`:

```yaml
# host_vars/vps-docker.yml
crowdsec_collections_extra:
  - crowdsecurity/caddy                  # parser + generic HTTP scenarios
  - crowdsecurity/http-cve               # known-CVE exploitation attempts
  - crowdsecurity/whitelist-good-actors  # keeps real crawlers out of the ban list
```

They are two variables because a `host_vars` override replaces a list outright.
Setting `crowdsec_collections` on a host would drop `crowdsecurity/linux` and
disable sshd detection with nothing to indicate it. `tests/render-check.yml`
asserts the base list still holds.

`crowdsecurity/whitelist-good-actors` is worth calling out: it whitelists
legitimate crawlers at the postoverflow stage. Without it, an aggressive
Googlebot crawl can resemble scanning, and because decisions go to the central
LAPI, that ban would apply on every host in the fleet.

## Adding a log source

Add entries to `crowdsec_acquisitions` in `host_vars/<host>.yml`. Each key
becomes `/etc/crowdsec/acquis.d/<key>.yaml`, and the value is written verbatim
as that file's contents:

```yaml
crowdsec_acquisitions:
  <filename-without-extension>:
    source: <docker|file|journalctl|...>
    # ... source-specific keys ...
    labels:
      type: <parser type>
```

`labels.type` is the important part: it decides which parser the lines are fed
to. It must match what the parser expects (`caddy`, `nginx`, `syslog`, …) or
the lines arrive and are never parsed.

Removing an entry does **not** remove the file from the host — delete it there
by hand and restart CrowdSec.

### Caddy in a Docker container

The agent runs on the host as root, so it can read container logs through the
Docker socket directly. No bind mounts, no shipping logs to a file:

```yaml
# host_vars/vps-docker.yml
crowdsec_acquisitions:
  caddy-docker:
    source: docker
    container_name:
      - caddy          # exact container name, as shown by `docker ps`
    labels:
      type: caddy

crowdsec_collections_extra:
  - crowdsecurity/caddy
```

`crowdsecurity/caddy` provides the `crowdsecurity/caddy-logs` parser and pulls
in `crowdsecurity/base-http-scenarios`, which is where the actual detection
(scanners, crawlers, brute force, path traversal) lives.

Caddy must be logging **JSON** — that is what the parser expects, and it is
Caddy's default `log` format.

Useful keys for the `docker` source, beyond `container_name`:

| Key | Purpose |
|---|---|
| `container_name_regexp` | Match containers by pattern instead of exact name |
| `container_id` / `container_id_regexp` | Match by ID |
| `docker_host` | Non-default socket, e.g. `unix:///var/run/docker.sock` |
| `follow_stdout` / `follow_stderr` | Which stream to read (both default true) |
| `since` / `until` | Time window to read |
| `use_container_labels` | Discover containers by their Docker labels |

### A log file

```yaml
crowdsec_acquisitions:
  nginx-files:
    source: file
    filenames:
      - /var/log/nginx/*.log
    labels:
      type: nginx
```

### Another systemd unit

```yaml
crowdsec_acquisitions:
  postfix:
    source: journalctl
    journalctl_filter:
      - "_SYSTEMD_UNIT=postfix.service"
    labels:
      type: syslog
```

## Sharing SSH with fail2ban

Both watch sshd, and they are not independent: whichever bans first drops the
attacker's packets, so the other never sees enough failures to act. The
thresholds are set so CrowdSec wins.

| Detector | Fires at |
|---|---|
| `crowdsecurity/ssh-bf` | 6 failures faster than one per 10s |
| `crowdsecurity/ssh-slow-bf` | 11 failures faster than one per 60s |
| fail2ban (`fail2ban_maxretry`) | 15 failures in `fail2ban_findtime` |

CrowdSec first is what you want: its decision reaches the central LAPI and
every agent in the fleet, so an IP banned here is blocked everywhere. A
fail2ban ban stays on the host that saw it.

fail2ban is kept as a backstop rather than removed, because it is the only
part of this that keeps working when the CrowdSec agent, the LAPI or the
bouncer is down.

CrowdSec's buckets leak and fail2ban counts in a fixed window, so the ordering
cannot hold at every possible attack rate — somewhere in the middle they cross
over. It is tuned for the common case, a fast brute force.

Expect few SSH alerts regardless: sshd is on a non-standard port with port 22
denied, so scanners rarely reach it at all. Web traffic is unavoidable and will
always dominate. Check which system acted with `fail2ban-client status sshd`
against `cscli alerts list --scenario crowdsecurity/ssh-bf` on the master.

## The reverse proxy trap

If the service sits behind another proxy — Caddy behind Pangolin, anything
behind Cloudflare — its logs record the **proxy's** address as the client. Feed
that to CrowdSec and it will happily ban your own reverse proxy, taking the
site down for everyone.

Before enabling HTTP scenarios, make the proxied service log the real client:

- **Caddy**: set `servers.trusted_proxies` so it emits `request.client_ip`
  alongside `request.remote_addr`
- then confirm with `cscli explain` (below) that the IP CrowdSec extracts is
  the visitor's, not the tunnel's

## Verifying it works

Run these on the **agent** (`vps-docker`), not the master:

```bash
# 1. Are lines arriving, and are they being parsed?
cscli metrics
```

Look at the *Acquisition Metrics* table. `lines_read` climbing with
`lines_parsed` at zero means the source works but `labels.type` or the parser
is wrong.

```bash
# 2. Why is a line not parsing? Walks it through every stage.
cscli explain --log '<paste one JSON log line>' --type caddy

# 3. Are scenarios actually evaluating?
cscli metrics show scenarios

# 4. What has been decided? (queries the central LAPI via the agent's creds)
cscli alerts list
cscli decisions list
```

To confirm bans are really enforced on container traffic:

```bash
sudo iptables -L DOCKER-USER -n --line-numbers   # crowdsec rule present?
sudo ipset list crowdsec-blacklists | head       # populated?
```

## Troubleshooting

| Symptom | Where to look |
|---|---|
| `lines_read` rising, `lines_parsed` zero | `labels.type` does not match an installed parser; check `cscli parsers list`. A *partial* gap on the kernel source is normal — see *What is watched out of the box* |
| Parsed, but no alerts | Scenario not installed (`cscli scenarios list`), or the threshold genuinely is not met |
| Alerts on the master, but nothing blocked | Bouncer is not pulling; check `cscli metrics` on the master and the bouncer's log in `/var/log/` |
| Host traffic blocked, container traffic not | `DOCKER-USER` absent on the host, so the role dropped it — the play prints which chains it skipped |
| Bouncer dead after a reboot | `DOCKER-USER` did not exist yet at start; the role installs an `After=docker.service` drop-in for this |
| `firewall '${BACKEND}' is not supported` | The base config is upstream's raw template — `mode: ${BACKEND}` is normally substituted per package at build time. The role pins `mode` in the `.local` overlay, so re-running the playbook fixes it. Reproduce with `crowdsec-firewall-bouncer -c /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml -t` |
| `ExecStartPre` exits 1, `journalctl` shows nothing | A configured chain does not exist. `-t` runs the same init as a real start, so the config test fails too. The bouncer logs to `/var/log/crowdsec-firewall-bouncer.log`, not the journal — look there. Note `iptables_chains` applies to **both** families, so a chain must exist in ip6tables too; use `iptables_v4_chains` for IPv4-only ones like `DOCKER-USER` |
| Your own proxy gets banned | See *The reverse proxy trap* above |

## Operations on the master

```bash
docker exec crowdsec-master-crowdsec-1 cscli machines list
docker exec crowdsec-master-crowdsec-1 cscli bouncers list
docker exec crowdsec-master-crowdsec-1 cscli decisions list
```

Agents register under their inventory name. Renaming a host in the inventory
makes it register again under the new name and leaves the old machine and
bouncer behind — remove those with `cscli machines delete <name>` and
`cscli bouncers delete <name>`.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Ansible playbook that hardens Ubuntu VPS hosts. There is no build and no
unit test suite — the feedback loop is the three checks below, then `--check`,
then a real run against one host.

## Commands

```bash
ansible-galaxy collection install -r requirements.yml   # community.general, ansible.posix

# The three checks CI runs; run them locally after every edit.
ansible-playbook main.yml -i inventory --syntax-check
ansible-lint
ansible-playbook tests/render-check.yml   # variable shapes + design invariants

ansible-playbook main.yml -i inventory --list-hosts      # confirm targeting after inventory/group changes
ansible-inventory -i inventory --host <name>             # resolved vars for one host

# Real runs. Port 22 with -u root on a fresh box; the custom port and admin user afterwards.
ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 --ask-vault-pass -u root
ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 --ask-vault-pass -u domenik1023

ansible-playbook main.yml -i inventory --ask-vault-pass --check        # dry run
ansible-playbook main.yml -i inventory --ask-vault-pass --limit <host> # one host only

ansible-vault edit group_vars/all/vault.yml
```

`requirements.yml` pins `grafana.grafana` for the `alloy` role, so re-run the
collection install after pulling.

Most bugs here are Jinja, not Ansible, and neither `--syntax-check` nor
`ansible-lint` catches an expression that parses but evaluates to the wrong
type. `tests/render-check.yml` covers the derived variables; when adding a
tricky expression, add an assertion there — and confirm it fails when the
regression is present (`-e var=badvalue`), or it is not testing anything.

The render check also renders `roles/alloy/templates/config.alloy.j2` — a
relative `lookup('ansible.builtin.template', …)` resolves fine from `tests/`,
and `template_vars=` lets one assertion compare renders under different
toggles. Validate a rendered Alloy config against the real parser before
trusting it: `alloy fmt <file>` and `alloy validate <file>`, from the binary in
the release matching `alloy_agent_version`.

For anything the render check still cannot reach, write a throwaway play that
loads the role's `defaults/main.yml` via `vars_files`, renders the expression to
a file, and parse it back with Python to confirm the shape.

## Architecture

Two roles and two plays in `main.yml`, in this order: `config` (hardening) then
`alloy` (telemetry). The split is a play boundary rather than a second
`include_role` so the hardening role's task order stays a statement about
itself; `hardening.yml` records the switched SSH port with `set_fact`, and host
facts persist across plays within a run, so the second play still connects.

`config/tasks/main.yml` includes six files **and the order is load-bearing**:

`hostname.yml` → `user.yml` → `hardening.yml` → `sysctl.yml` → `software.yml` →
`crowdsec.yml`

- `hostname.yml` is first because the host's own name is what everything after
  it records itself as, and the Alloy play labels all its telemetry with it.
- `hardening.yml` installs `python3-debian`, which `deb822_repository` in
  `software.yml` and `crowdsec.yml` needs and a stock Ubuntu image lacks.
- `software.yml` starts Docker before `crowdsec.yml` probes for `DOCKER-USER`.

The `alloy` play must stay after it: cAdvisor and the Docker log discovery both
expect the socket `software.yml` creates.

### Host targeting

Both plays run against `all:!lapi`. The `[lapi]` group holds the central
CrowdSec LAPI server, which exists in the inventory **only** as a `delegate_to`
target — a delegate absent from the inventory silently falls back to SSH
defaults (port 22, no `ansible_user`). Configuring it would disable the very
LAPI the fleet depends on.

Within the hardening play, `when: "'local' not in group_names"` skips SSH
hardening (to avoid self-lockout on LAN test boxes) and the entire CrowdSec
include. Alloy is not skipped there — a LAN box reaches the default
`ingest.net.d1023.de` without any override.

Hosts are named in `inventory`; addresses and per-host settings live in
`host_vars/<name>.yml`. The name is not cosmetic — `crowdsec_lapi_login` and
`crowdsec_bouncer_name` derive from `inventory_hostname`, so renaming a host
orphans its machine and bouncer registration on the LAPI.

### The mid-play SSH port switch

`hardening.yml` moves sshd off port 22 while Ansible is connected over it:
allow the current port in UFW *before* `ufw enable`, `limit` the new port,
restart sshd, `set_fact ansible_port`, `wait_for_connection`, then deny port 22.
Reordering any of this locks you out. `ansible.cfg` sets `pipelining` and
`ControlPersist` for a related reason: without connection reuse, per-task
reconnects trip UFW's `limit` rule and surface as "Connection refused".

### CrowdSec

Agents run as **log processors only** — the local API server is disabled and
alerts go to the central LAPI, so bans propagate fleet-wide. See
`docs/crowdsec.md` for the operational side (adding log sources, verification,
troubleshooting).

`crowdsec_credentials.yml` mints machine credentials and the bouncer API key by
running `cscli` on the LAPI host over delegation; nothing is stored in the
vault. It is idempotent by **verify-then-mint**: check what the agent already
has (`cscli lapi status` for the machine, an authenticated `GET /v1/decisions`
for the bouncer key) and only generate a new secret when the existing one is
missing, points elsewhere, or is rejected. Preserve that property when editing.
`crowdsec_lapi_cscli` is the invocation prefix, which is how a LAPI running in
a container is reached (`docker exec <container> cscli …`).

### Alloy

`roles/alloy` is a thin wrapper: it renders `templates/config.alloy.j2` and
hands it to `grafana.grafana.alloy`, which does the install. Everything tunable
lives in its `defaults/main.yml`; see `docs/alloy.md` for the operational side.

Three of its variables are deliberately renamed because upstream defines the
same names — `alloy_agent_version`, `alloy_service_user` and
`alloy_service_extra_groups`, mapped onto `alloy_version`,
`alloy_systemd_override` and `alloy_user_groups` as **include parameters**.
Role defaults from both roles sit at the same precedence and the role loaded
second wins, so an `alloy_version` in our defaults would be silently replaced by
upstream's `"latest"` — which queries the GitHub API every run and can upgrade a
host unasked. Include parameters outrank every default while still leaving
host_vars free to override. Do not "simplify" this back into matching names.

**Log sources are shipped raw except Traefik's access log.**
`alloy_extra_log_paths` tails files and forwards them unparsed, on the Loki
principle that parsing belongs at query time. `alloy_traefik_access_log` is the
one exception, with a `loki.process` pipeline behind it, because three things
cannot be recovered at query time: a real timestamp (otherwise a replayed
backlog invents a traffic spike), `trace_id` as structured metadata (which is
what makes a line clickable through to Tempo), and dropping lines before they
count against Loki's ingestion limits. Only `entrypoint` becomes a real label —
anything with unbounded values would create a Loki stream per value.

**Regexes interpolated into the Alloy config must go through `to_json`.** Alloy
string literals take Go's escape sequences, so an everyday
`^/favicon\.ico$` in `alloy_traefik_drop_paths` is an "unknown escape sequence"
that fails the entire config file — not just its stage — and the agent stops on
its next restart. `alloy validate` from the pinned release catches it;
`tests/render-check.yml` asserts the escaping so CI catches it first.

`alloy_config` is rendered with `set_fact` rather than inline in the
`include_role` vars, and that is also not stylistic: variables are templated
lazily at the point of use, and a relative template lookup resolves against the
role of the task doing the using — which for `alloy_config` is a task inside
`grafana.grafana.alloy`, whose `templates/` does not contain our file.

## Conventions and traps

**CrowdSec config goes in `.local` overlays**, never the base file. Package
upgrades overwrite the base; the overlay survives and takes precedence. The
bouncer's `mode` is pinned there for this reason — upstream ships the base
config as a template whose `mode: ${BACKEND}` is substituted at package build
time, and a base file that lost that substitution otherwise stops the bouncer
dead.

**Handlers fire in definition order, not notification order.** `Reload systemd`
is first in `handlers/main.yml` so it precedes any service it affects.

**Facts must be read as `ansible_facts['name']`.** `ansible.cfg` sets
`inject_facts_as_vars = False`, so `ansible_distribution_release` and friends
are undefined.

**Package name ≠ service name ≠ backend mode** for the CrowdSec bouncer:
`crowdsec-firewall-bouncer-iptables` is the package, `crowdsec-firewall-bouncer`
the unit, `iptables` the mode. Separate variables exist for each.

**`iptables_chains` applies to IPv4 and IPv6 both.** A chain listed there must
exist in both families or the bouncer aborts at startup — and its `-t` config
test runs the same initialisation, so systemd never starts it. IPv4-only chains
like `DOCKER-USER` go in `crowdsec_bouncer_iptables_v4_chains`, which is probed
before use.

**UFW does not filter Docker-published ports.** Docker's `FORWARD` jump precedes
UFW's, so `-p 8080:80` is reachable regardless of firewall rules. This is
accepted, not fixed; CrowdSec compensates via `DOCKER-USER`. Fail2ban shares
the blind spot.

**Fail2ban is deliberately duller than CrowdSec** so CrowdSec bans first and the
decision reaches the whole fleet. The two are not independent — whichever bans
first starves the other of events. Changing `fail2ban_maxretry` without
checking it against the `ssh-bf` / `ssh-slow-bf` thresholds inverts that.

**`docker_userns_remap` is off deliberately.** It breaks any container that
bind-mounts `/var/run/docker.sock` and relocates Docker's data root, hiding
existing containers and volumes.

**Alloy's `instance` label comes from the system hostname, not the inventory.**
`constants.hostname` and the journal's `_HOSTNAME` field feed it, in seven places
across the config — so a host whose local name differs from its inventory name
ships telemetry no dashboard filtering on the inventory name will match.
`hostname.yml` closes that by setting the system hostname to
`inventory_hostname`, which is why it fixes all six at once and no relabelling
is needed. Alloy reads the hostname once at startup and its config carries no
literal copy, so a rename does not change the config and upstream's handler
never fires — `roles/alloy` restarts it explicitly on the fact `hostname.yml`
sets. Facts persist across plays, which is what makes that work.

**The Alloy config is templated twice.** `grafana.grafana.alloy` writes
`alloy_config` with `ansible.builtin.template`, so whatever `config.alloy.j2`
renders passes through Jinja again on the way to disk. Anything reaching that
second pass still holding an opening Jinja delimiter is evaluated and discarded
silently — the file lands short of a pipeline and Alloy starts happily without
it. `tests/render-check.yml` asserts against this.

**Alloy's three listeners stay on loopback.** OTLP (4317/4318), the profile
receiver (4041) and the UI (12345) are all unauthenticated and Alloy has no
credential checking to enable. No UFW rule is added for any of them, and that is
deliberate twice over: nothing needs to reach them, and any `ufw` rule change
reloads UFW, which deletes every non-builtin chain and takes the CrowdSec
bouncer's rules with it. The `Reload UFW` handler notifies a bouncer restart for
that reason, and it is scoped to `roles/config` — a rule added from `roles/alloy`
could not reach it.

**Alloy's ingest endpoints are unauthenticated by design.** Agents cannot do
interactive OIDC. Do not add credentials to the agent config expecting the
server to check them; nothing does.

`group_vars/all/vault.yml` holds only `vault_admin_password`, which must be a
crypt hash — `user.yml` asserts this, because the `user` module writes the value
into `/etc/shadow` verbatim and a plaintext value leaves the account with no
usable password.

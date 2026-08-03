# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Ansible playbook that hardens Ubuntu VPS hosts. There is no build, no test
suite and no linter configured — the feedback loop is `--syntax-check`, then
`--check`, then a real run against one host.

## Commands

```bash
ansible-galaxy collection install -r requirements.yml   # community.general, ansible.posix

ansible-playbook main.yml -i inventory --syntax-check   # fastest check; run after every edit
ansible-playbook main.yml -i inventory --list-hosts      # confirm targeting after inventory/group changes
ansible-inventory -i inventory --host <name>             # resolved vars for one host

# Real runs. Port 22 with -u root on a fresh box; the custom port and admin user afterwards.
ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 --ask-vault-pass -u root
ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 --ask-vault-pass -u domenik1023

ansible-playbook main.yml -i inventory --ask-vault-pass --check        # dry run
ansible-playbook main.yml -i inventory --ask-vault-pass --limit <host> # one host only

ansible-vault edit group_vars/all/vault.yml
```

Verifying template/filter logic without a target host is worth doing — most
bugs here are Jinja, not Ansible. Write a throwaway play that loads
`roles/config/defaults/main.yml` via `vars_files`, renders the expression to a
file, and parse it back with Python to confirm the shape.

## Architecture

One role, `config`, included by `main.yml`. Its `tasks/main.yml` includes five
files **and the order is load-bearing**:

`user.yml` → `hardening.yml` → `sysctl.yml` → `software.yml` → `crowdsec.yml`

- `hardening.yml` installs `python3-debian`, which `deb822_repository` in
  `software.yml` and `crowdsec.yml` needs and a stock Ubuntu image lacks.
- `software.yml` starts Docker before `crowdsec.yml` probes for `DOCKER-USER`.

### Host targeting

`main.yml` runs against `all:!lapi`. The `[lapi]` group holds the central
CrowdSec LAPI server, which exists in the inventory **only** as a `delegate_to`
target — a delegate absent from the inventory silently falls back to SSH
defaults (port 22, no `ansible_user`). Configuring it would disable the very
LAPI the fleet depends on.

Within the play, `when: "'local' not in group_names"` skips SSH hardening (to
avoid self-lockout on LAN test boxes) and the entire CrowdSec include.

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

`group_vars/all/vault.yml` holds only `vault_admin_password`, which must be a
crypt hash — `user.yml` asserts this, because the `user` module writes the value
into `/etc/shadow` verbatim and a plaintext value leaves the account with no
usable password.

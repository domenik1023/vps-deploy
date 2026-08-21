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
collection install after pulling. CI pins its tooling too —
`ansible-core~=2.19.0` and `ansible-lint~=26.6.0` in `.github/workflows/ci.yml`
— so a newer local `ansible-lint` can report findings CI never sees, and the
reverse. `.ansible-lint` skips two rules on purpose; `no-handler` is the one
that matters, because the four tasks it flags are the mid-play SSH port switch
and the sysctl apply, which must run inline (a handler fires at the end of the
play, by which point sshd has already moved and the connection is dead).

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
loads the role's defaults via `vars_files`, renders the expression to a file,
and parse it back with Python to confirm the shape. `roles/baseline/defaults/`
is a `main/` **directory**, which Ansible loads whole but `vars_files` cannot
take — so list its files individually, as `tests/render-check.yml` does. The
first assertion in that file compares the list it loaded against a glob of the
directory, because a seventh defaults file nobody wired up would otherwise be
untested and silent about it.

## Architecture

Two roles and two plays in `main.yml`, in this order: `baseline` (everything
every managed host gets) then `alloy` (telemetry). The split is a play boundary
rather than a second `include_role` so the baseline role's task order stays a
statement about itself; `42_ssh.yml` records the switched SSH port with
`set_fact`, and host facts persist across plays within a run, so the second play
still connects.

`baseline/tasks/main.yml` includes its files **in a load-bearing order**, and
they are numbered so that order is visible in `ls` rather than only in a
comment. A new file gets a number that places it, not the next one free:

`10_hostname` → `20_user` → `30_packages` → `40_firewall` → `41_fail2ban` →
`42_ssh` → `50_sysctl` → `60_updates` → `61_time` → `62_docker` →
`70_crowdsec`

- `10_hostname.yml` is first because the host's own name is what everything
  after it records itself as, and the Alloy play labels all its telemetry with
  it.
- `20_user.yml` before `42_ssh.yml`, which locks the root account last.
- `30_packages.yml` installs `python3-debian`, which `deb822_repository` in
  `62_docker.yml` and `70_crowdsec.yml` needs and a stock Ubuntu image lacks.
- `40_firewall.yml` strictly before `42_ssh.yml`: the bootstrap allow on the
  live session's port and the `limit` on the port sshd is about to move to must
  both exist before it moves. The matching deny on the old port lives in
  `42_ssh.yml` instead, next to the move that justifies it.
- `62_docker.yml` starts Docker before `70_crowdsec.yml` probes for
  `DOCKER-USER`.

The `alloy` play must stay after it: cAdvisor and the Docker log discovery both
expect the socket `62_docker.yml` creates.

Each include carries a **tag** named after its concern, so one can be re-run on
its own (`--tags docker`, `--tags crowdsec`). They are for a converged host, not
for bootstrapping: `--tags crowdsec` on a fresh box skips `42_ssh.yml`, so the
`set_fact` that moves `ansible_port` never runs and every task after it tries
the wrong port.

**Free-form file bodies live in `templates/`; data structures stay in the
task.** `daemon.json` and the CrowdSec bouncer overlay are built as mappings and
written with `to_nice_json` / `to_nice_yaml`, where the round trip through the
filter is itself the check that the shape is right — those stay inline. An sshd
drop-in, a fail2ban jail, a systemd unit or the sysctl file is text with holes
in it, and belongs in `templates/`.

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

`42_ssh.yml` moves sshd off port 22 while Ansible is connected over it:
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

`71_crowdsec_credentials.yml` mints machine credentials and the bouncer API key by
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

**Log sources are shipped raw except proxy access logs.**
`alloy_extra_log_paths` tails files and forwards them unparsed, on the Loki
principle that parsing belongs at query time. `alloy_access_logs` is the
exception, with a `loki.process` pipeline per entry, because three things
cannot be recovered at query time: a real timestamp (otherwise a replayed
backlog invents a traffic spike), `trace_id` as structured metadata (which is
what makes a line clickable through to Tempo), and dropping lines before they
count against Loki's ingestion limits.

Each entry names a `format`, which indexes `alloy_access_log_formats` — the
field maps for `traefik` and `caddy`, kept as data so adding a proxy is one
entry there and no template change. `job` defaults to the format name and is
interpolated into the component names, so two access logs on one host need
distinct jobs. Only fields bounded to a handful of values become real Loki
labels (`entrypoint` on Traefik, nothing on Caddy); everything else is
structured metadata, because each distinct value of a real label is another
Loki stream. `tests/render-check.yml` caps the label list to keep that from
being undone by accident. Note Caddy emits no trace IDs in access log lines,
unlike Traefik — the timestamps and dropping are the reason to parse its logs.

**Regexes interpolated into the Alloy config must go through `to_json`.** Alloy
string literals take Go's escape sequences, so an everyday
`^/favicon\.ico$` in an entry's `drop_paths` is an "unknown escape sequence"
that fails the entire config file — not just its stage — and the agent stops on
its next restart. `alloy validate` from the pinned release catches it;
`tests/render-check.yml` asserts the escaping so CI catches it first. Note that
single-quoted YAML passes backslashes through untouched while a Jinja string
literal unescapes them — writing the test fixture the wrong way makes that
assertion pass whether the template escapes or not.

**Every job label is `integrations/<suffix>`, and the template owns the
prefix.** A `job` in `alloy_extra_log_paths`, `alloy_access_logs` or
`alloy_extra_scrape_targets` is the suffix only — writing the prefix yourself
doubles it. This is the convention every dashboard and every query in
`docs/alloy.md` filters on, so a job that opts out fails by showing nothing
rather than by erroring; `tests/render-check.yml` rejects any rendered job label
without the prefix.

`alloy_extra_scrape_targets` covers anything already exposing a Prometheus
endpoint on the host. Two of its fields are sharper than they look: `name`
becomes the `prometheus.scrape` block label, so it must be a bare Alloy
identifier (a slash there is the parse error that motivated the per-host render
check), and `address` is a bare `host:port` — a URL scrapes a host that does not
exist and only shows up as a target that never comes up. `instance` is pinned to
the hostname rather than left to default to `host:port`, so these line up with
every other job.

**The tunable Alloy collections are lists of mappings, never mappings.** Ansible
does not guarantee mapping order, and an unordered render changes the config
file on every run — which reports `changed` forever and restarts Alloy each
time. The render check asserts the shape for each of them.

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

**`crowdsec_firewall_log_prefix` is written verbatim into `before.rules`.** It
lands inside a double-quoted `--log-prefix` argument that `iptables-restore`
parses, so a stray quote or newline does not fail the play — it fails `ufw
reload`, which leaves the firewall stopped with a default-ACCEPT policy. iptables
also caps prefixes at 29 characters, and the prefix must contain neither
`ACCEPT` nor `UFW AUDIT`: those are `crowdsecurity/iptables-logs`' two filter
exclusions, and matching either makes the parser silently discard every line it
exists to read. Note also that `ufw_logging` is for reading by hand only —
ufw rate-limits its own LOG rules at every level below `high`, so the rule
CrowdSec actually reads is a separate, unlimited one installed by `70_crowdsec.yml`.

**Fail2ban is deliberately duller than CrowdSec** so CrowdSec bans first and the
decision reaches the whole fleet. The two are not independent — whichever bans
first starves the other of events. Changing `fail2ban_maxretry` without
checking it against the `ssh-bf` / `ssh-slow-bf` thresholds inverts that.

**`docker_userns_remap` is off deliberately.** It breaks any container that
bind-mounts `/var/run/docker.sock` and relocates Docker's data root, hiding
existing containers and volumes.

**Alloy's `instance` label comes from the system hostname, not the inventory.**
`constants.hostname` and the journal's `_HOSTNAME` field feed it, in six places
across the config — so a host whose local name differs from its inventory name
ships telemetry no dashboard filtering on the inventory name will match.
`10_hostname.yml` closes that by setting the system hostname to
`inventory_hostname`, which is why it fixes all six at once and no relabelling
is needed. Alloy reads the hostname once at startup and its config carries no
literal copy, so a rename does not change the config and upstream's handler
never fires — `roles/alloy` restarts it explicitly on the fact `10_hostname.yml`
sets. Facts persist across plays, which is what makes that work.

**The Alloy config is templated twice.** `grafana.grafana.alloy` writes
`alloy_config` with `ansible.builtin.template`, so whatever `config.alloy.j2`
renders passes through Jinja again on the way to disk. Anything reaching that
second pass still holding an opening Jinja delimiter is evaluated and discarded
silently — the file lands short of a pipeline and Alloy starts happily without
it. `tests/render-check.yml` asserts against this.

**Alloy's listeners stay on loopback by default.** OTLP (4317/4318), the profile
receiver (4041) and the UI (12345) are all unauthenticated and Alloy has no
credential checking to enable. No UFW rule is added for any of them by default,
and that is deliberate twice over: nothing needs to reach them, and any `ufw`
rule change reloads UFW, which deletes every non-builtin chain and takes the
CrowdSec bouncer's rules with it. The `Reload UFW` handler notifies a bouncer
restart for that reason, and it is scoped to `roles/baseline` — a rule added from
`roles/alloy` could not reach it, which is why `ufw_allow_rules` lives in
`roles/baseline` even though its only current caller is Alloy.

Widening `alloy_ui_bind` costs more than the bind address. `alloy_custom_args`
emits `--server.http.listen-addr` only when the bind differs from Alloy's own
default, because upstream's post-install preflight parses that flag and runs the
address through `ansible.utils.ipaddr` — and `ansible.utils` is neither in
`requirements.yml` nor a dependency of `grafana.grafana`, so emitting the flag
fails the play with a missing-filter error. Reach the UI over
`ssh -L 12345:localhost:12345 <host>` instead.

`alloy_otlp_extra_receivers` is the one sanctioned widening, for a sender that
genuinely cannot reach loopback — a container run with
`network_mode: service:<other>` has no namespace of its own, so `localhost`
inside it is the *other* container's loopback. Traefik on `vps-pangolin` is
exactly this. It renders a second `otelcol.receiver.otlp` on a Docker bridge
gateway, keeping the loopback one, and it needs a matching `ufw_allow_rules`
entry: container-to-gateway traffic traverses `INPUT`, where UFW's default-deny
drops it, and Docker's own rules are in `FORWARD` and never see it.
`tests/render-check.yml` asserts every rendered listener stays in a private
range, so `0.0.0.0` cannot be set by accident.

**`tests/render-check.yml` must assert against rendered host_vars, not just
defaults.** It loads both roles' defaults with `vars_files`, so any
assertion naming one of those variables is checking the *default* — a host_vars
file overriding it is invisible. That gap shipped a `prometheus.scrape
"instance/traefik"` past green CI, which Alloy rejects outright. The per-host
task renders every `host_vars/*.yml` through the template and checks the
properties that decide whether the config parses at all; new invariants about
host-settable variables belong there.

**Alloy's ingest endpoints are unauthenticated by design.** Agents cannot do
interactive OIDC. Do not add credentials to the agent config expecting the
server to check them; nothing does.

`group_vars/all/vault.yml` holds only `vault_admin_password`, which must be a
crypt hash — `20_user.yml` asserts this, because the `user` module writes the value
into `/etc/shadow` verbatim and a plaintext value leaves the account with no
usable password.

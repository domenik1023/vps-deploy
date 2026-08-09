# Grafana Alloy

Every host this playbook manages runs one Grafana Alloy agent, which collects
metrics, logs, traces and profiles and pushes them to the central observability
stack. This covers what it collects, how to point a host at the right ingest
hostname, adding a log source, and what to look at when data stops arriving.
Setup lives in the [Grafana Alloy section of the README](../README.md#grafana-alloy).

## How it fits together

```
  vps-docker                             monitoring host
  ┌───────────────────────────┐          ┌──────────────────────────────┐
  │ alloy                     │          │  Caddy (ingest.*.d1023.de)   │
  │  ├─ node exporter         │          │   ├─ /api/v1/write ──► Prom  │
  │  ├─ cAdvisor              │  push    │   ├─ /loki/api/v1/push ► Loki│
  │  ├─ journald ─────────────┼─────────►│   ├─ /v1/traces ─────► Tempo │
  │  ├─ Docker stdout         │  HTTPS   │   ├─ /push.v1…/Push ─┐       │
  │  ├─ OTLP :4318 (loopback) │          │   └─ /ingest ────────┴► Pyro │
  │  └─ Pyroscope :4041 (lo)  │          │                              │
  └───────────────────────────┘          │  Grafana ── reads all four   │
                                         └──────────────────────────────┘
```

Agents **push**; nothing scrapes them. That is worth internalising, because it
inverts the usual failure signal: when a host dies its metrics simply stop
arriving rather than going to zero, so no `up == 0` alert can see it. The
monitoring host pings each host separately for that — see
[Adding a host](#adding-a-host).

Each signal has a distinct write path, so a single ingest hostname routes all
four with no prefix rewriting:

| Path | Signal |
|---|---|
| `/api/v1/write` | metrics |
| `/loki/api/v1/push` | logs |
| `/v1/traces` | traces |
| `/push.v1.PusherService/Push` | profiles, from the agent |
| `/ingest` | profiles, from a language SDK |

Only the first two are written out in the rendered config. The other three are
appended by Alloy itself: `otelcol.exporter.otlphttp` adds `/v1/traces` and
`pyroscope.write` adds `/push.v1.PusherService/Push`, so `alloy_tempo_endpoint`
and `alloy_pyroscope_endpoint` are base URLs. Putting the path in either gives a
doubled path and a 404 that surfaces only as a failed export in Alloy's own log.
`/ingest` is the SDK path, served on this host by `pyroscope.receive_http` on
`localhost:4041`; the reverse proxy needs it too for anything pushing profiles
directly.

## The two ingest hostnames

Both names reach the same reverse proxy and the same backends. Only the network
path differs:

| Hostname | Reachable from | Used by |
|---|---|---|
| `https://ingest.net.d1023.de` | LAN and tunnel only | hosts on 192.168.2.x — the default |
| `https://ingest.d1023.de` | the internet | off-site hosts — the `vps` group |

The LAN name is the default in `roles/alloy/defaults/main.yml`, so a host on the
LAN needs no configuration at all. Off-site hosts are switched a whole group at a
time, which `group_vars/vps.yml` already does:

```yaml
alloy_ingest_base: "https://ingest.d1023.de"
```

All four signal endpoints derive from that one value; `tests/render-check.yml`
asserts they still do, which is what makes the one-line override trustworthy.
Override an individual `alloy_loki_endpoint` / `alloy_prom_endpoint` /
`alloy_tempo_endpoint` / `alloy_pyroscope_endpoint` only to send one signal
somewhere else, such as a staging Tempo.

The rendered config carries the resolved hostname in a header comment, so one
command on a host says which one it actually got:

```bash
head -3 /etc/alloy/config.alloy
```

> Both endpoints are **unauthenticated by design** — an agent cannot do
> interactive OIDC, and nothing on the server checks credentials. Do not add
> them to the agent config expecting them to be verified. If that changes it
> will change on `ingest.d1023.de` first, since that is the internet-facing one.

## What is collected out of the box

| Signal | Source | Toggle |
|---|---|---|
| Host metrics | `prometheus.exporter.unix`, with the `systemd` collector on | always |
| Container metrics | `prometheus.exporter.cadvisor` over the Docker socket | `alloy_enable_docker` |
| Alloy's own metrics | `prometheus.exporter.self` | always |
| systemd journal | `loki.source.journal`, relabelled to `unit` / `level` / `boot_id` | `alloy_enable_journal` |
| Container stdout | `loki.source.docker`, labelled with the compose project and service | `alloy_enable_docker` |
| Log files | `loki.source.file` | `alloy_extra_log_paths` |
| Traces | `otelcol.receiver.otlp` on `127.0.0.1:4317` and `:4318` | `alloy_enable_otlp` |
| Profiles (SDK) | `pyroscope.receive_http` on `127.0.0.1:4041` | `alloy_enable_profiles` |
| Profiles (whole host) | `pyroscope.ebpf` | `alloy_enable_ebpf` |

The toggles are not cosmetic. A host without Docker that still has the container
blocks compiled in logs socket errors continuously and leaves both components
permanently unhealthy — it does not fail loudly once. Every host this playbook
manages gets Docker from `roles/config/tasks/software.yml`, so the default is on.

The `compose_service` label is deliberate: Tempo's `tracesToLogsV2` maps a span's
`service.name` onto it, which is what makes the jump from a trace to that
container's logs work in Grafana.

### Why native and not a container

Alloy needs `/proc`, `/sys`, the journal, the Docker socket, `/dev/kmsg`, and —
for eBPF — the host PID namespace and kernel tracing. A container gets all of
that only by being given host networking, host PID, root and eight capabilities,
at which point it isolates nothing and only adds mount juggling. A native install
has the access inherently.

Hosts that genuinely cannot take a deb — Alpine, NAS firmware, immutable
distributions — are the exception, and they should run the compose file from the
`grafana` repo with whatever container mechanism they already use, rather than
adding a second Alloy code path here.

### Why it runs as root

The packaged unit runs as the unprivileged `alloy` user, which cannot read the
cgroup hierarchy cAdvisor needs, cannot read `/dev/kmsg` for container OOM
detection, and cannot load eBPF programs. `alloy_service_user` is therefore
`root`, written into `/etc/systemd/system/alloy.service.d/override.conf`.

Everything except eBPF works unprivileged. On a host where that matters:

```yaml
alloy_service_user: alloy
alloy_service_extra_groups:
  - systemd-journal
  - docker
```

and add `AmbientCapabilities=CAP_DAC_READ_SEARCH CAP_SYSLOG` to the override.
Try it on one host first: cAdvisor's cgroup access is the part most likely to
break, and it breaks by reporting no container metrics rather than by failing
the run.

## Adding a log source

Applications that log to stdout in a container are already collected. Anything
writing to disk needs a path adding, in `host_vars/<name>.yml`:

```yaml
alloy_extra_log_paths:
  - { path: "/tmp/logs/*.log", job: "python" }
  - { path: "/tmp/pangolin/*.log", job: "pangolin" }
```

`job` becomes the Loki `job` label, which is what you query on. It is a list and
not a mapping so the rendered config keeps a stable order — unordered output
would make the deploy report `changed` on every run and restart Alloy with it.
`tests/render-check.yml` asserts both the list shape and that every entry has
both keys; an entry missing `job` ships its lines under an empty label, where
nothing in Grafana is looking for them.

Files are tailed from the end on first run, so a large existing log is not
replayed into Loki.

## Firewall

| Port | What | Exposure |
|---|---|---|
| 4317, 4318 | OTLP receiver | host-local only |
| 4041 | Pyroscope SDK receiver | host-local only |
| 12345 | Alloy UI and `/metrics` | host-local only |

All three are unauthenticated, and Alloy has no credential checking to turn on.
**No UFW rule is added for any of them**, which is a decision rather than an
omission: nothing needs to reach them from outside, and touching UFW here would
be actively harmful. Adding a rule reloads UFW, `ufw reload` is a stop/start that
deletes every non-builtin chain, and that takes the CrowdSec firewall bouncer's
rules with it. The `Reload UFW` handler in `roles/config` notifies a bouncer
restart for exactly this reason; a rule added from the Alloy role would be
outside that handler's scope and would leave the host unprotected until the next
bouncer restart.

The UI is worth reaching — it shows the live component graph and is how you
diagnose a pipeline that quietly stopped collecting. Use a tunnel:

```bash
ssh -p 22822 -L 12345:localhost:12345 domenik1023@vps-docker
# then open http://localhost:12345
```

Widening `alloy_ui_bind` needs more than editing one variable: the loopback
binds are asserted in `tests/render-check.yml`, and the upstream role's preflight
validates a non-default listen address with `ansible.utils.ipaddr`, which is not
in `requirements.yml`. A host that needs to send telemetry should run its own
agent rather than reach across to this one.

## Versions

`alloy_agent_version` is pinned in the role defaults, and the version bump *is*
the upgrade: the upstream role installs the release asset from GitHub directly,
so there is no APT repository and no `apt upgrade` path. That keeps the fleet's
version declarative in git.

Leaving it at upstream's `latest` would query the GitHub API on every run and
silently upgrade a host, which is why it is not left there. The variable is
deliberately not called `alloy_version`: role defaults from both roles sit at
the same precedence and the role loaded second wins, so an `alloy_version` here
would be replaced by upstream's `"latest"` without a word.
`roles/alloy/tasks/main.yml` maps it across as an include parameter, which
outranks every default.

To upgrade the fleet, change one line and re-run:

```yaml
alloy_agent_version: "1.19.0"
```

## eBPF profiling

Off by default — it is the only pipeline with prerequisites that fail at run
time rather than at render time, and it fails by putting one component into an
error state while the rest of the agent carries on. Nothing looks broken; the
profiles just never arrive.

A host that sets `alloy_enable_ebpf: true` needs:

- Alloy running as root in the host PID namespace — both free with the default
  `alloy_service_user: root` on a native install
- `/sys/kernel/tracing` readable (on older kernels, `/sys/kernel/debug`)
- a writable `/tmp/symb-cache` for the symbol cache
- kernel 5.9+ ideally; below that `SYS_ADMIN` substitutes for
  `CHECKPOINT_RESTORE`
- on Ubuntu with a strict AppArmor profile, possibly an unconfined profile

Running unprivileged instead needs `BPF`, `PERFMON`, `SYS_PTRACE`,
`CHECKPOINT_RESTORE`, `SYS_RESOURCE`, `DAC_READ_SEARCH` and `SYSLOG`.

`pyroscope.ebpf` is generally available from Alloy 1.18, so **no
`--stability.level` flag is needed** — advice to the contrary predates its
promotion out of public preview.

Turn it on for one host, look at the flame graphs, then decide.

## Verifying it works

1. The service is up and the config parsed:

   ```bash
   systemctl status alloy
   head -3 /etc/alloy/config.alloy      # confirms which ingest hostname it got
   curl -s localhost:12345/-/ready
   ```

2. No component is stuck. Alloy logs a healthy start once and then goes quiet;
   repeated errors naming a component are the thing to look for:

   ```bash
   journalctl -u alloy -n 50 --no-pager
   ```

   The component graph at `http://localhost:12345` (over the tunnel above) shows
   the same thing visually, including which components are feeding which.

3. **A second playbook run reports zero changed tasks.** If the config task
   reports `changed` every time, the template is producing unstable output —
   an unordered mapping or something time-derived.

4. The data actually lands. From Grafana on the monitoring host:

   | Explore | Query | Expect |
   |---|---|---|
   | Prometheus | `up{job="integrations/node", instance="vps-docker"}` | `1` |
   | Prometheus | `up{job="integrations/alloy", instance="vps-docker"}` | `1` |
   | Loki | `{job="integrations/journal", instance="vps-docker"}` | log lines |
   | Loki | `{job="integrations/docker", instance="vps-docker"}` | log lines |

## Adding a host

After a new host is deployed, add its IP to
`server/prometheus/targets/blackbox-icmp.yml` in the `grafana` repo, and bump the
`AgentFleetShrunk` threshold in `server/prometheus/rules/host.yml`.

That file is the authoritative host-down signal. Agents push, so a dead host's
metrics stop arriving rather than going to zero, and no `up == 0` alert can
detect it — only a ping from the monitoring box can. `AgentFleetShrunk` is the
canary for the case this step was forgotten. Prometheus re-reads the target file
every 30 seconds, so it needs no restart.

## Troubleshooting

| Symptom | Where to look |
|---|---|
| `alloy` will not start | `journalctl -u alloy -n 100 --no-pager`. A config it cannot parse names the line; `/etc/alloy/config.alloy` is the rendered file, but fix `roles/alloy/templates/config.alloy.j2` and re-run rather than editing it in place. |
| Config on disk is missing a whole pipeline | The block reached upstream's second templating pass holding a Jinja delimiter and was evaluated away. `tests/render-check.yml` asserts against this; run it. |
| Config task reports `changed` on every run | The template output is not byte-stable. Look for an iterated mapping or anything time-derived; `alloy_extra_log_paths` is a list for this reason. |
| No metrics at all from a host, agent healthy | Endpoint resolution. `head -3 /etc/alloy/config.alloy` — an off-site host pointed at `ingest.net.d1023.de` cannot route there. Check the host is in the `vps` group. |
| Container metrics missing, everything else fine | cAdvisor's cgroup access. `systemctl show alloy -p User` should say `root`; a host on the unprivileged path will not have it. |
| Container logs missing, container metrics present | `discovery.docker` cannot reach the socket. Check `alloy_docker_host` and that the containers are actually running — discovery lists nothing when there is nothing to list. |
| Journal logs missing | The `alloy` user is not in `systemd-journal` and is not root. Only relevant on the unprivileged path. |
| Traces sent but never appear in Tempo | `alloy_tempo_endpoint` has a path on it. It must be a base URL — the exporter appends `/v1/traces` itself, and the doubled path 404s silently. |
| Profiles sent but never appear in Pyroscope | Same shape of mistake: `alloy_pyroscope_endpoint` is a base URL, and `pyroscope.write` appends `/push.v1.PusherService/Push`. Check the reverse proxy routes both that and `/ingest`. |
| eBPF profiles missing, other profiles fine | `pyroscope.ebpf` is in an error state. Needs root, `/sys/kernel/tracing` and a writable `/tmp/symb-cache`; check the component graph in the UI. |
| A host stopped reporting and nothing alerted | It was never added to `server/prometheus/targets/blackbox-icmp.yml`. Agents push, so silence is indistinguishable from a healthy idle host without the ICMP probe. |
| Playbook fails on `ansible.utils.ipaddr` | `alloy_ui_bind` was widened, which makes the upstream role's preflight validate the listen address. Add `ansible.utils` to `requirements.yml`, or put the UI back on loopback. |
| Version keeps changing across runs | `alloy_agent_version` is not reaching the upstream role, which falls back to `latest` and queries the GitHub API each run. Check the include parameters in `roles/alloy/tasks/main.yml`. |

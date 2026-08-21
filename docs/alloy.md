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
| `https://ingest.net.d1023.de` | LAN and tunnel only | every LAN host — the default |
| `https://ingest.d1023.de` | the internet | off-site hosts — the `vps` group |

The LAN name is the default in `roles/alloy/defaults/main.yml`, so a LAN host
needs no configuration at all, whichever subnet it sits on. Off-site hosts are switched a whole group at a
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
| Log files | `loki.source.file`, shipped raw | `alloy_extra_log_paths` |
| Proxy access logs | `loki.source.file` into `loki.process`, parsed as JSON | `alloy_access_logs` |
| Endpoints already on the host | `prometheus.scrape` (Traefik, an app's `/metrics`) | `alloy_extra_scrape_targets` |
| Traces | `otelcol.receiver.otlp` on `127.0.0.1:4317` and `:4318` | `alloy_enable_otlp` |
| Profiles (SDK) | `pyroscope.receive_http` on `127.0.0.1:4041` | `alloy_enable_profiles` |
| Profiles (whole host) | `pyroscope.ebpf` | `alloy_enable_ebpf` |

The toggles are not cosmetic. A host without Docker that still has the container
blocks compiled in logs socket errors continuously and leaves both components
permanently unhealthy — it does not fail loudly once. Every host this playbook
manages gets Docker from `roles/baseline/tasks/62_docker.yml`, so the default is on.

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

`job` is the *suffix*: the rendered label is `integrations/<job>`, so
`job: python` is queried as `{job="integrations/python"}`. The template owns the
prefix so every signal in the fleet shares one naming convention. It is a list and
not a mapping so the rendered config keeps a stable order — unordered output
would make the deploy report `changed` on every run and restart Alloy with it.
`tests/render-check.yml` asserts both the list shape and that every entry has
both keys; an entry missing `job` ships its lines under an empty label, where
nothing in Grafana is looking for them.

Files are tailed from the end on first run, so a large existing log is not
replayed into Loki.

### Raw or parsed

`alloy_extra_log_paths` ships lines **raw** and you parse at query time with
LogQL — `| json`, `| logfmt`, `| pattern`. That is the idiomatic Loki approach
and it is the right default: it costs nothing at ingest, it survives a log
format changing under you, and Caddy, Pangolin and anything else writing
structured JSON are perfectly queryable that way.

Parsing at ingest is worth it only when it buys something query-time parsing
cannot, which in practice is three things:

- **Timestamps.** Without a `stage.timestamp` Loki stamps each line with the
  time it arrived. That is invisible until the agent replays a backlog after a
  restart or a rotation, when a burst of old lines all land at "now" and invent
  a traffic spike that never happened.
- **Structured metadata.** `trace_id` has to be attached at ingest for Grafana
  to put a "View trace" button on the line. Query-time extraction is too late.
- **Dropping.** Lines dropped at the agent never count against Loki's
  ingestion rate limits. Query-time filtering happens after you have paid.

Reverse-proxy access logs are the sources that get that treatment, because they
are where all three apply at once. Everything else stays raw.

### Access logs

One entry per log file, in `host_vars/<name>.yml`:

```yaml
alloy_access_logs:
  - path: /mnt/docker/pangolin/logs/access.log
    format: traefik
    drop_paths:                    # optional, regex against the request path
      - "^/health$"
  - path: /mnt/docker/caddy/logs/access.log
    format: caddy
```

`format` picks the field map out of `alloy_access_log_formats` in the role
defaults — `traefik` or `caddy` today, and adding a third proxy is a new entry
there and nothing else. `job` defaults to the format name and is the suffix of
the Loki label (`integrations/traefik`) as well as part of the component names,
so it has to be a valid Alloy identifier — no slashes, dots or dashes. Two logs
on one host therefore need distinct `job` values.

> **Both parsers are JSON parsers.** A proxy left on its default plain-text
> access log errors on every line, which surfaces as an error counter on the
> component rather than as anything the play notices. The per-proxy setup is
> below.

Only bounded fields become real Loki labels — `entrypoint` for Traefik, nothing
for Caddy. Everything else (`status`, `method`, `path`, `host`, `client`,
`duration`, and `trace_id`/`span_id` where the proxy emits them) becomes
structured metadata, which is queryable and indexed without creating a stream
per distinct value. Do not promote `path`, `client` or `router` to
`stage.labels`: each distinct value there is a new stream, and
`tests/render-check.yml` caps the label list to stop it happening by accident.

`drop_paths` entries are ordinary regexes — `"^/favicon\\.ico$"` in YAML, which
is one backslash once YAML is done with it. The template runs each through
`to_json` on the way into the config, because Alloy's string literals take Go's
escape sequences and a bare `\.` is an "unknown escape sequence" that fails the
*whole* config file, not just that stage.

## Scraping something that already exposes metrics

Anything on the host with its own Prometheus endpoint — a reverse proxy, an
application's `/metrics`, a bare exporter — is added as a scrape target:

```yaml
alloy_extra_scrape_targets:
  - { name: "traefik", address: "127.0.0.1:8082" }
```

`name` becomes the component label and the default job suffix
(`integrations/traefik`), so it has to be a valid Alloy identifier — letters,
digits and underscores, not starting with a digit. It is interpolated straight
into the block name, where anything else is a parse error that stops the agent
on its next restart. `address` is a bare `host:port`, not a URL. Both are
asserted in `tests/render-check.yml`. `job`, `path`, `scheme` and `interval` are
optional; `job` is the suffix only, so do not write the `integrations/` prefix
yourself.

The `instance` label is pinned to the hostname rather than left to default to
the scraped `host:port`, so these jobs filter the same way as every other one.

> **Publish the port to loopback.** A target on a Docker-published port must be
> published as `127.0.0.1:8082:8082`, never `8082:8082`. Docker's `FORWARD` jump
> precedes UFW's, so a plainly published port is reachable from the internet
> whatever the firewall says — the same trap CrowdSec compensates for via
> `DOCKER-USER`.

### Traefik

`vps-pangolin` runs Traefik as part of the Pangolin stack. The two signals need
quite different amounts of work.

**Traefik's own runtime log needs nothing here.** It goes to stdout in Docker,
so `loki.source.docker` already collects it — the lines are in Loki under
`{job="integrations/docker", instance="vps-pangolin"}`, labelled with the
compose project and service.

**The access log gets its own pipeline.** Traefik does not emit one by default;
turn it on in Traefik, writing to a file:

```yaml
# static config
accessLog:
  filePath: /mnt/docker/pangolin/logs/access.log
  format: json
```

then name that file in `host_vars/<name>.yml`, as
[Access logs](#access-logs) describes:

```yaml
alloy_access_logs:
  - path: /mnt/docker/pangolin/logs/access.log
    format: traefik
```

> **`format: json` is not optional.** The pipeline parses these lines, and the
> parser is a JSON one. Pointed at Traefik's default common-log format it errors
> on every line — which surfaces as an error counter on the component in the UI,
> not as anything the play notices.

Traefik is the proxy where this pays off most, because it is the one that puts
trace IDs in its access log lines — and a trace ID only becomes a clickable
"View trace" button if it is attached as structured metadata at ingest.

**Tracing, if you want requests followable end to end.** Point Traefik at the
local agent's OTLP receiver:

```yaml
# static config
tracing:
  otlp:
    http:
      endpoint: http://localhost:4318/v1/traces
  sampleRate: 1.0
```

> That endpoint is the **full path**. Traefik wants `/v1/traces` appended,
> unlike `OTEL_EXPORTER_OTLP_ENDPOINT` elsewhere — and unlike
> `alloy_tempo_endpoint` in this repo — which take a base URL and append the
> path themselves. Getting it backwards produces 404s that look like the
> collector is down.

`localhost:4318` is this host's own agent. It is bound to loopback so nothing
external can reach it, and the agent handles batching and retry on the way to
Tempo. Once tracing is on, Traefik adds trace IDs to every access log line by
itself — no `fields` configuration — and the pipeline above picks them up.

#### When Traefik shares another container's network namespace

`localhost` only works if Traefik can reach *this host's* loopback. In the
Pangolin stack it cannot: Traefik runs with `network_mode: service:gerbil`, so
it has no network namespace of its own and `localhost` inside it is gerbil's
loopback. Nothing is listening there, and the export fails.

Note this also rules out `extra_hosts: host.docker.internal:host-gateway` on
the Traefik service — Docker rejects host mappings on a container that joins
another container's namespace, because `/etc/hosts` comes from the owner. It
would have to go on gerbil.

Three things have to line up, and each fails silently on its own:

**1. Alloy needs a second receiver on the bridge gateway.** The loopback one
stays, so host-local senders are unaffected:

```yaml
# host_vars/vps-pangolin.yml
alloy_otlp_extra_receivers:
  - { name: "docker", address: "172.19.0.1" }
```

**2. UFW has to let that traffic in.** Container-to-gateway packets arrive on
the bridge interface and traverse the host's `INPUT` chain — Docker's own rules
live in `FORWARD` and never see them — so UFW's default-deny drops them. The
rule belongs in `roles/baseline`, because `ufw reload` flushes the CrowdSec
bouncer's chains and only that role's handler puts them back:

```yaml
ufw_allow_rules:
  - src: "172.19.0.0/16"
    dest: "172.19.0.1"
    port: "4317,4318"
    proto: tcp
    comment: "Traefik in gerbil's netns to the Alloy OTLP receiver"
```

**3. Traefik points at the gateway, with the full path:**

```yaml
tracing:
  otlp:
    http:
      endpoint: http://172.19.0.1:4318/v1/traces
```

Find the gateway with:

```bash
docker inspect gerbil -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'
```

> **Pin the subnet in the compose file.** A user-defined network's subnet is
> allocated dynamically, so recreating it can move the gateway — and Alloy would
> then be listening on an address nothing reaches, with no error anywhere.

The receiver is still unauthenticated, so every container on the host can push
spans to it. A gateway address is not routable from the internet, which is what
keeps that bounded; `tests/render-check.yml` asserts every listener stays in a
private range so `0.0.0.0` cannot be set by accident.

If gerbil itself runs with `network_mode: host`, none of this applies —
Traefik is already in the host namespace and plain `localhost:4318` works.

**Metrics need enabling and then scraping.** Traefik serves Prometheus metrics
on the `traefik` entryPoint at `/metrics` once switched on, and that entryPoint
is the same one the insecure API dashboard uses — so give metrics their own:

```yaml
# static config
entryPoints:
  metrics:
    address: ":8082"
metrics:
  prometheus:
    entryPoint: metrics
    addRoutersLabels: true    # off by default; per-router series
```

```yaml
# compose: loopback only, so the port is not published to the internet
ports:
  - "127.0.0.1:8082:8082"
```

```yaml
# host_vars/vps-pangolin.yml
alloy_extra_scrape_targets:
  - { name: "traefik", address: "127.0.0.1:8082" }
```

`addEntryPointsLabels` and `addServicesLabels` are already on by default;
`addRoutersLabels` is not, and it is the one that gives per-router request rates
and latencies. It also multiplies series count by the number of routers, so turn
it on deliberately.

Verify from Grafana: `up{job="integrations/traefik", instance="vps-pangolin"}`
should be `1`, and `traefik_service_requests_total` should have series.

### Caddy

`vps-docker` runs Caddy in Docker. Same two signals, both needing a change on
the Caddy side first.

**Caddy's own runtime log needs nothing** — it goes to stdout and arrives
through `loki.source.docker` already.

**The access log needs writing to a file.** Caddy logs to stdout by default, and
those lines do reach Loki through the Docker pipeline, but raw — no real
timestamps, no dropping. Point it at a file the host can see:

```caddyfile
# Caddyfile — inside the site block, or as a global `log` for all sites
log {
    output file /var/log/caddy/access.log
    format json {
        time_format rfc3339_nano
    }
}
```

```yaml
# compose: the path above has to be a bind mount the host can read
volumes:
  - /mnt/docker/caddy/logs:/var/log/caddy
```

```yaml
# host_vars/vps-docker.yml — the host-side path, not the container-side one
alloy_access_logs:
  - path: /mnt/docker/caddy/logs/access.log
    format: caddy
```

> **`time_format rfc3339_nano` matters.** Caddy's default `ts` is a float epoch,
> which `stage.timestamp` reads far less predictably than RFC3339Nano. The stage
> is set to `fudge` rather than `skip` on failure, so getting this wrong costs
> you accurate timestamps rather than the logs themselves — which makes it the
> kind of thing that goes unnoticed.

Note that Caddy, unlike Traefik, does **not** put trace identifiers into access
log lines just because tracing is enabled, so these lines get no "View trace"
button. The timestamps and the drop handling are the reason to parse them.

**Metrics need enabling and then scraping**, and the obvious route is the wrong
one. Caddy serves `/metrics` on its **admin endpoint** (`:2019`), but that
endpoint is unauthenticated and can rewrite Caddy's running configuration —
publishing it to the host, even on loopback, hands config-change ability to
anything on the box. Use a dedicated `metrics` route instead:

```caddyfile
# global options
{
    metrics
}

# a site block of its own, on its own port
:2020 {
    metrics /metrics
}
```

```yaml
# compose: loopback only, per the Docker/UFW trap above
ports:
  - "127.0.0.1:2020:2020"
```

```yaml
# host_vars/vps-docker.yml
alloy_extra_scrape_targets:
  - { name: "caddy", address: "127.0.0.1:2020" }
```

Verify from Grafana: `up{job="integrations/caddy", instance="vps-docker"}` should
be `1`, and `caddy_http_requests_total` should have series. Until Caddy actually
serves that port the target reports `up == 0` rather than nothing at all, so do
the Caddy side and the playbook run close together.

## Firewall

| Port | What | Exposure |
|---|---|---|
| 4317, 4318 | OTLP receiver | host-local only |
| 4041 | Pyroscope SDK receiver | host-local only |
| 12345 | Alloy UI and `/metrics` | host-local only |
| 4317, 4318 on a bridge gateway | OTLP, for containers that cannot reach loopback | opt-in per host, private range only |

All of them are unauthenticated, and Alloy has no credential checking to turn
on. **No UFW rule is added by default**, which is a decision rather than an
omission: nothing needs to reach them from outside, and touching UFW is not
free. Adding a rule reloads UFW, `ufw reload` is a stop/start that deletes every
non-builtin chain, and that takes the CrowdSec firewall bouncer's rules with it.
The `Reload UFW` handler in `roles/baseline` notifies a bouncer restart for
exactly this reason — which is also why `ufw_allow_rules` lives in that role and
not in `roles/alloy`, since handlers are only reachable from the role that
defines them.

The last row is the one sanctioned exception, and it is not a widening of the
first: it adds a *second* receiver rather than moving the first off loopback.
The case that forces it is a container that cannot reach this host's loopback at
all — one run with `network_mode: service:<other>`, where `localhost` is the
other container's namespace. That needs both `alloy_otlp_extra_receivers` and a
matching `ufw_allow_rules` entry, because container-to-gateway traffic traverses
`INPUT` where UFW's default-deny drops it. See
[When Traefik shares another container's network namespace](#when-traefik-shares-another-containers-network-namespace).

What keeps that bounded is the address: a Docker bridge gateway is not routable
from the internet, though every container on the host can reach it.
`tests/render-check.yml` renders each host and asserts every listener it finds
sits in a private range, so `0.0.0.0` cannot be set by accident.

Note that upstream's own `alloy_expose_port` is **not** the escape hatch it
looks like. It drives `ansible.posix.firewalld`, and these hosts run UFW —
firewalld is not installed. The role queries the `firewalld` unit first, gets
`LoadState=not-found` back, and skips the rule without failing, so setting
`alloy_expose_port: true` on Ubuntu opens nothing and reports nothing. Opening
a port here means a `community.general.ufw` task, which is what the paragraph
above says not to add.

The UI is worth reaching — it shows the live component graph and is how you
diagnose a pipeline that quietly stopped collecting. Use a tunnel:

```bash
ssh -p 22822 -L 12345:localhost:12345 domenik1023@vps-docker
# then open http://localhost:12345
```

Widening `alloy_ui_bind` needs more than editing one variable: the binds are
asserted in `tests/render-check.yml`, and the upstream role's preflight
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
   | Prometheus | `up{job="integrations/node_exporter", instance="vps-docker"}` | `1` |
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
| A host's data is missing under `instance="<inventory name>"` | Its system hostname does not match. `instance` comes from the host's own name in all six pipelines, not from the inventory. Run `hostname` on the box and query without the filter — `{job="integrations/journal"}` — to see what label it is actually using. `10_hostname.yml` sets this; a host predating it, or with `system_hostname_manage: false`, keeps the old name. |
| Renamed a host and its graphs went flat | Expected: old series and log streams keep the previous `instance`, new ones arrive under the new name. Queries spanning the change need both. |
| No metrics at all from a host, agent healthy | Endpoint resolution. `head -3 /etc/alloy/config.alloy` — an off-site host pointed at `ingest.net.d1023.de` cannot route there. Check the host is in the `vps` group. |
| Container metrics missing, everything else fine | cAdvisor's cgroup access. `systemctl show alloy -p User` should say `root`; a host on the unprivileged path will not have it. |
| Container logs missing, container metrics present | `discovery.docker` cannot reach the socket. Check `alloy_docker_host` and that the containers are actually running — discovery lists nothing when there is nothing to list. |
| Journal logs missing | The `alloy` user is not in `systemd-journal` and is not root. Only relevant on the unprivileged path. |
| Traefik traces never arrive, everything else fine | Traefik cannot reach the agent. If it runs with `network_mode: service:<other>`, `localhost` is that container's loopback, not the host's — see [Traefik](#traefik). Check all three: `alloy_otlp_extra_receivers`, the `ufw_allow_rules` entry, and Traefik's endpoint carrying the full `/v1/traces` path. |
| Traces stopped after recreating a Docker network | The bridge gateway moved. `alloy_otlp_extra_receivers` still names the old address, so Alloy listens where nothing sends. Pin the subnet in the compose file. |
| Traces sent but never appear in Tempo | `alloy_tempo_endpoint` has a path on it. It must be a base URL — the exporter appends `/v1/traces` itself, and the doubled path 404s silently. |
| Profiles sent but never appear in Pyroscope | Same shape of mistake: `alloy_pyroscope_endpoint` is a base URL, and `pyroscope.write` appends `/push.v1.PusherService/Push`. Check the reverse proxy routes both that and `/ingest`. |
| eBPF profiles missing, other profiles fine | `pyroscope.ebpf` is in an error state. Needs root, `/sys/kernel/tracing` and a writable `/tmp/symb-cache`; check the component graph in the UI. |
| An extra scrape target never comes up | `address` is a bare `host:port` — a URL there scrapes a host that does not exist. If the endpoint is a Docker-published port, check it is published (`docker port <container>`) and that the bind is `127.0.0.1`, which Alloy on the host can still reach. |
| `alloy` will not start after editing a host_vars entry | A block label that is not an Alloy identifier — a `name` or `job` holding a slash, dot or dash renders `prometheus.scrape "instance/traefik"`, which fails with "expected block label to be a valid identifier". `tests/render-check.yml` renders every host_vars file and checks this, so CI catches it now. |
| `alloy` will not start after adding a drop path | An "unknown escape sequence" in the rendered config. Alloy's strings take Go's escapes, so a regex backslash must be doubled — the template's `to_json` does that, and `tests/render-check.yml` asserts it. A drop path that reached the file unescaped fails the whole config, not just its stage. |
| Access log lines missing, or the component erroring | The pipeline parses JSON and the proxy is not writing it. Traefik needs `accessLog.format: json`, Caddy needs `format json`; a plain-text access log errors on every line. Check the `alloy_access_logs` path is the one the host sees, not the container-side path. |
| Access log arrives, but all at the same timestamp | `stage.timestamp` could not read the time field and fell back. It is `fudge` rather than `skip`, so lines still arrive. Traefik: check `StartUTC` is present. Caddy: this is the default float `ts` — set `time_format rfc3339_nano`. |
| No "View trace" button on a Traefik log line | No trace ID in the line. Traefik only adds them once `tracing` is configured — see [Traefik](#traefik). The pipeline reads the snake_case `trace_id`/`span_id` pair, which is what the Loki datasource's derived field matches on. Caddy never emits them, so its lines have no button by design. |
| Traefik metrics missing, Traefik logs present | Metrics are off in Traefik itself until `metrics.prometheus` is set; the container logging to stdout is independent of it. Per-router series additionally need `addRoutersLabels: true`. |
| A host stopped reporting and nothing alerted | It was never added to `server/prometheus/targets/blackbox-icmp.yml`. Agents push, so silence is indistinguishable from a healthy idle host without the ICMP probe. |
| Playbook fails on `ansible.utils.ipaddr` | `alloy_ui_bind` was widened, which makes the upstream role's preflight validate the listen address. Add `ansible.utils` to `requirements.yml`, or put the UI back on loopback. |
| `alloy_expose_port: true` opened nothing | It is firewalld-only, and these hosts run UFW. The role skips the rule silently when the `firewalld` unit is not found. See [Firewall](#firewall) before adding a UFW rule instead. |
| Version keeps changing across runs | `alloy_agent_version` is not reaching the upstream role, which falls back to `latest` and queries the GitHub API each run. Check the include parameters in `roles/alloy/tasks/main.yml`. |

# TODO

## Move the WireGuard peer key into group_vars

`wg_peer_public_key` is per-host today, but it is the *server's* instance key —
one UDP port is one WireGuard instance and an instance has exactly one public
key, so every `[vpn]` host on the same endpoint repeats the same value.
It belongs in `group_vars/vpn.yml` alongside `wg_peer_endpoint`, with host_vars
free to override for a host on a different instance.

`tests/render-check.yml` already asserts the two agree across hosts; that check
becomes mostly redundant once the value is defined in one place, but it still
covers a host that overrides one and not the other.

## Strip inline comments and write real docs

The role files, defaults and templates carry most of this repo's reasoning as
comments. Move it into `docs/`, one page per concern, and leave the code
readable.

`CLAUDE.md` overlaps heavily with what would move — decide whether it stays the
index or is itself generated from the docs.

## Create the OPNsense peer automatically

Registering a `[vpn]` host is manual: run the play once to print the public
key, add the peer in the UI, attach it to the instance, hit Apply, then add the
firewall rule. OPNsense has a REST API and this playbook already declines to
use it.

Automating it removes the two failure modes that cost the most time — a peer
saved but never applied, and a peer registered but never granted access by a
firewall rule. See `docs/opnsense-firewall.md` and `docs/wireguard.md`.

## ~~Make "Bring up the tunnel" resilient~~ — done

`roles/wireguard/tasks/tunnel.yml`, the `Bring up the tunnel` task. Restarting
`wg-quick@wg0` moves the default route while Ansible is mid-connection, and the
privilege escalation prompt (or the task's own acknowledgement) could be cut
off by the change it is causing:

```
[ERROR]: Task failed: Timeout (12s) waiting for privilege escalation prompt:
Origin: roles/wireguard/tasks/tunnel.yml:411:3
```

Fixed with `async: {{ wg_bringup_async_timeout }}` / `poll: 0` on that task, so
it no longer waits synchronously for a reply over the connection its own side
effect is about to disrupt. "Wait for the host to answer with the tunnel up",
right after it, is what actually needs the connection back, and it already
retries a fresh one for up to 60s. `tests/render-check.yml` asserts both
settings are present and that this task precedes the wait.

# TODO

## Move the WireGuard peer key into group_vars

`wg_peer_public_key` is per-host today, but it is the *server's* instance key —
one UDP port is one WireGuard instance and an instance has exactly one public
key, so every `[vpn]` host on the same endpoint repeats the same value.
It belongs in `group_vars/vpn.yml` alongside `wg_peer_endpoint`, with host_vars
free to override for a host on a different instance.

`tests/render-check.yml` does not just become redundant - it breaks. That play
has no inventory, so it reads `host_vars/*.yml` directly and never loads
`group_vars/vpn.yml`. Two assertions go with the value:

- `wg_peer_public_key` is in `wg_required`, so "Any host_vars naming a tunnel
  must name all of it" fails for every `[vpn]` host.
- the endpoint/key collection is gated on both being defined, so `wg_peers`
  comes out empty and the `length > 0` guard - deliberately there to stop the
  assertion passing on nothing - fails.

So the move is: relocate the value, load `group_vars/vpn.yml` into the test,
and rewrite both assertions against the merged view rather than the file. That
last part is the work, and it is what keeps the override case covered.

## Keep new host_vars lean

Decided: the reasoning stays as comments next to the code it is about. A
`roles/` comment is read by whoever is editing that line; the same text on a
`docs/` page is read by nobody at the moment it would have helped. `CLAUDE.md`
stays the index.

What was actually painful was the other end - writing `host_vars/<name>.yml`
by hand, by copying a reference file that is more explanation than value.
`.claude/skills/new-host/` handles that now: it asks for the facts that cannot
be derived (name, class, address, and for `[vpn]` the peer registered on
OPNsense), checks them against the invariants `tests/render-check.yml`
enforces, and writes a short file from `templates/<class>.yml.tmpl` plus the
inventory line.

Keep generated host files lean. The long-form versions in
`host_vars/vpn-example.yml.example` and the existing hosts stay as reference.

Still open: nothing forces the skill's templates and the real invariants to
agree. A new required host_vars setting has to be added in three places -
the role, `tests/render-check.yml`, and the template.

## Create the OPNsense peer automatically

Registering a `[vpn]` host is manual: run the play once to print the public
key, add the peer in the UI, attach it to the instance, hit Apply, then add the
firewall rule. OPNsense has a REST API and this playbook already declines to
use it.

Automating it removes the two failure modes that cost the most time — a peer
saved but never applied, and a peer registered but never granted access by a
firewall rule. See `docs/opnsense-firewall.md` and `docs/wireguard.md`.

## Make "Bring up the tunnel" survive its own routing change

`roles/wireguard/tasks/tunnel.yml`, the `Bring up the tunnel` task. Restarting
`wg-quick@wg0` moves the default route while Ansible is mid-connection:

```
[ERROR]: Task failed: Timeout (12s) waiting for privilege escalation prompt:
Origin: roles/wireguard/tasks/tunnel.yml:411:3
```

A longer escalation timeout is not the fix. The kill switch is already armed
before this task runs, and the thing keeping an *existing* SSH session alive
across the move is the connmark half alone - `mangle PREROUTING` marks the
connection, `mangle OUTPUT` restores the mark, and the `ip rule` at
`wg_killswitch_rule_priority` sends it to the main table. The
`--sport <ssh_port> RETURN` rule in `filter OUTPUT` is not a second chance at
this: `filter OUTPUT` runs *after* the routing decision, so once routing has
picked `wg0` the packet matches `! -o $WAN -j RETURN` at the top of the chain
and leaves down the tunnel. Not dropped, just gone.

So the run currently requires one TCP connection to survive a default-route
change with its conntrack mark intact. That is the fragile part, not the
timeout.

The fix is to stop requiring it:

1. Split `enabled: true` into its own `systemd_service` task - it moves no
   routes.
2. Start the unit detached, so nothing has to report back over the connection
   the change is about to invalidate:
   `systemd-run --no-block --unit=wg-bringup systemctl {start,restart} wg-quick@wg0`,
   preceded by a `systemctl reset-failed wg-bringup` exactly as the rollback
   arming at `tunnel.yml:363` already does.
3. `meta: reset_connection`, then `wait_for_connection`. A *new* SSH session is
   the reliable case: `PREROUTING` marks it at the SYN, so the whole flow is
   marked from the start.

Costs, all of which need handling in the same change:

- Detaching loses the module's error reporting - a `wg-quick` that fails to
  start looks like success. Add an explicit `systemctl is-active` check after
  the reconnect, or the failure surfaces later as "never handshaked" and sends
  whoever reads it to the OPNsense side for a local problem.
- `meta: reset_connection` ignores `when:`, so it runs in check mode too.
- The rollback timer stays the backstop for a host that never comes back.

## Wait for the handshake before waiting for the connection

Separate bug, same file, found while looking at the above. On a host with
`vpn_ip` set, `ansible_host` is the tunnel address, so the reconnect can only
succeed *after* the handshake. But `Wait for the host to answer with the
tunnel up` (timeout 60) runs before `Wait for a handshake with the WireGuard
server` (retries 30, delay 5). The comment on the handshake task records
`vpn-gwdg-01` handshaking 60-70s in - past the 60s the connection wait allows.

No host has `vpn_ip` set today, which is why this has not bitten. Either raise
the connection wait to match, or wait for the handshake first - it needs no
connection of its own beyond the one that issued it.


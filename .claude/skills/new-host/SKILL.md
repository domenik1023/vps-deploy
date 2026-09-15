---
name: new-host
description: Add a new managed host to this Ansible inventory. Use when asked to add, onboard, register, define or create a host, VPS, box, server, LAN machine or WireGuard peer, or to write a host_vars file. Interviews for the facts that cannot be derived, writes host_vars/<name>.yml and the inventory entry, and runs the repo's checks.
---

# Add a host

Interview the user, then write two things: `host_vars/<name>.yml` and one line
in `inventory`. Nothing else in the repo changes.

**Never invent a value.** Every address, key and port here is something only
the user knows. A guessed one fails on a real box, usually after the run has
already hardened it. If an answer is missing, ask; if the user says "whatever
you think", that is still a question for them.

**Keep the generated file short.** The reference templates in
`host_vars/vpn-example.yml.example` and the existing host files carry long
explanations; a new file should not. One header line, the values, and a
pointer to `docs/`. The reasoning lives in `docs/` and `CLAUDE.md`.

## 1. Ask

In this order. Stop at the first unanswered question rather than filling the
rest in.

**Always:**

1. **Name.** Becomes `inventory_hostname`, the system hostname
   (`10_hostname.yml`), Alloy's `instance` label, and — on `[vps]`/`[vpn]` —
   the CrowdSec `machine` and `bouncer` registration on the shared LAPI.
   Renaming later orphans both registrations. Check it is not already in
   `inventory` or `host_vars/`.
2. **Class** — exactly one of:
   - `[vps]` — internet-facing, own public address. Full SSH hardening,
     CrowdSec agent + bouncer.
   - `[vpn]` — internet-facing, default route through the OPNsense WireGuard
     tunnel. Everything `[vps]` gets, plus the tunnel and kill switch.
   - `[local]` — on the LAN behind NAT. No SSH port move, no CrowdSec.
3. **Address** to reach it on. For `[local]` the LAN address; for the others
   the public address it currently answers on.
4. **Is this a fresh box or already hardened?** Fresh → `ansible_port: 22` for
   the bootstrap run, and the run happens `-u root`. Already converged →
   `ansible_port: 22822` (`ssh_port`) and `-u domenik1023` (`admin_user`).
   `[local]` stays on 22 permanently.
5. **A non-default login user for the bootstrap run?** Some images ship
   `cloud`, `ubuntu` or `debian` rather than root — that is `ansible_user`
   (see `host_vars/vpn-gwdg-01.yml`). Skip if root.

**`[vpn]` only** — all of it comes off the peer registered on OPNsense, see
`docs/wireguard.md` §1:

6. **`wg_address`** — the address assigned to this peer, as a `/32`. Must match
   the peer's Allowed IPs on OPNsense exactly.
7. **`wg_peer_endpoint`** — OPNsense's `host:port`. If another `[vpn]` host
   already uses this endpoint, reuse its `wg_peer_public_key` without asking;
   one UDP port is one instance and one key.
8. **`wg_peer_public_key`** — only when the endpoint is new. This is the
   *server's* instance key, never this host's own. Getting it backwards is
   silent: the tunnel comes up and never handshakes.
9. **`wg_dns`** — a public resolver (`9.9.9.9` is what the fleet uses); there
   is no LAN resolver reachable from an isolated peer.
10. **A preshared key on the OPNsense peer entry?** If yes, it must be
    vaulted, and the user pastes the output of
    `ansible-vault encrypt_string --name wg_preshared_key '<PresharedKey>'`
    themselves. Never write a preshared key in plain text.

**Optional, offer but do not press** — these can be added later and each needs
a service already running on the box:

- `alloy_extra_scrape_targets` — a bare `host:port` (no scheme), `name` a bare
  Alloy identifier (no slashes, no dashes).
- `alloy_access_logs` — a proxy access log to parse; `format` is `traefik` or
  `caddy`.
- `crowdsec_acquisitions` / `crowdsec_collections_extra` — `[vps]`/`[vpn]`
  only.

## 2. Check before writing

- **No other `host_vars` file may name the same `ansible_host` *and*
  `ansible_port`.** `grep -n 'ansible_host\|ansible_port' host_vars/*.yml`.
  A duplicate means a run against the new name SSHes into the old box and
  reconfigures it under the wrong identity — renaming it, splitting its
  telemetry, and reusing its WireGuard private key. `crowdsec-master`
  deliberately shares `komodo`'s address and is the one exception.
- **The name is free** in both `inventory` and `host_vars/`.
- **`[vpn]`: the endpoint/key pair agrees** with every other host on that
  endpoint.

## 3. Write

Copy the matching `templates/<class>.yml.tmpl` from this skill directory, fill in the
answers, replace every `<PLACEHOLDER>`, and drop every commented line the user did not ask for. Ordering:
`ansible_host`, `ansible_port`, `ansible_user`, then the tunnel block, then
anything Alloy or CrowdSec.

Then add the name to the right group in `inventory`, under the existing
entries for that group. Leave the group's comment block alone.

## 4. Verify

```bash
ansible-playbook main.yml -i inventory --syntax-check
ansible-lint
ansible-playbook tests/render-check.yml
ansible-playbook main.yml -i inventory --list-hosts
```

`render-check.yml` is the one that matters here: it re-reads every
`host_vars/*.yml` and enforces the uniqueness, tunnel-completeness and
endpoint/key rules above. `--list-hosts` confirms the host landed in exactly
one class — `00_classify.yml` fails the run otherwise, but only once the run
has started.

## 5. Tell them what to run

Report the file written, the inventory group, and the next command. Never run
a play against the new host yourself.

`[local]` and `[vps]`, fresh box:

```bash
ansible-playbook main.yml -i inventory --private-key=~/.ssh/domenik1023 --ask-vault-pass -u root
```

Then say: set `ansible_port: 22822` in the host_vars file afterwards, and use
`-u domenik1023` from then on. (`[local]` stays on port 22 and keeps whatever
user it has.)

`[vpn]` is **two runs**, and saying so up front saves a confused first attempt:

1. First run generates the keypair, prints the host's public key, and stops
   before touching routing.
2. Register that public key on OPNsense as a peer with `wg_address` as its
   Allowed IPs, attach it to the instance, **Apply**, and add the firewall
   rule (`docs/opnsense-firewall.md` — a peer that is saved but not applied,
   or applied but not granted a rule, is the usual failure).
3. Run again. The tunnel comes up, and the play arms a rollback timer that
   undoes everything unless the host answers *and* the tunnel handshakes.

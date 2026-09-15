# OPNsense firewall rules for WireGuard peers

**Registering a peer grants it no access.** The tunnel comes up, handshakes,
and carries nothing. This page is the other half of
[docs/wireguard.md](wireguard.md): what has to exist on OPNsense before a
`[vpn]` host can reach anything.

None of it is automated. The playbook configures the client and never touches
the server side — see `TODO.md`.

## Why it fails silently

A missing firewall rule does not produce an error anywhere. OPNsense drops the
packets, the peer sees no reply, and every symptom points at the tunnel:

- `wg show` reports a completed handshake, so crypto and reachability are fine
- `transfer:` stays at or near `0 B received`
- with no traffic flowing, WireGuard never rekeys, so you see **one** handshake
  and then nothing — which reads as an unstable tunnel rather than a
  permissions problem

The playbook makes this worse in one specific way: the Alloy play runs after
the tunnel is up and fetches its release from GitHub *through* it. So a peer
that can reach OPNsense but not the internet fails the run at Alloy, several
tasks after the thing that is actually wrong.

## The two things that must exist

### 1. A firewall rule on the WireGuard interface

**Not on WAN.** OPNsense filters on the interface a packet *enters* the
firewall on. A peer's traffic arrives encrypted on WAN, is decrypted, and
enters on the WireGuard interface (`opt1`/`wg0`, or the assigned name) — so
that is the tab the rule belongs on.

The default policy on a WireGuard/OPT interface is to allow **nothing**, so
the rule has to be added explicitly. For a full-tunnel `[vpn]` host it needs to
be broad: these hosts originate arbitrary outbound connections (apt, GitHub,
container registries, telemetry), so a rule scoped to particular destinations
will keep failing in new ways.

Source is the peer's tunnel address, or the tunnel subnet if you would rather
cover every peer with one rule. That choice matters for a reason worth knowing:
if the existing rules on this tab are scoped to individual peer addresses —
because the other peers are narrower things, an admin's management access or a
game server that only ever *receives* forwarded traffic — then a new
full-tunnel peer matches none of them. That is what "every peer works except
this one" looks like.

### 2. Outbound NAT covering the tunnel subnet

Set Outbound NAT to **Automatic**, or add a manual rule covering the tunnel
subnet out the WAN interface. Without it the peer's packets reach OPNsense,
get routed, and leave with an unroutable source address.

This is the difference between "can reach OPNsense" and "can reach the
internet", and it is worth keeping separate from rule 1 when diagnosing.

## Apply

OPNsense stores WireGuard and firewall changes and pushes them to the running
system only when you **Apply**. A saved-but-unapplied peer or rule looks
completely correct in the UI and does not exist to the kernel.

Confirm from OPNsense's own shell rather than the UI:

```sh
wg show          # does the peer's public key appear at all?
```

If the key is not listed, nothing was applied yet — no amount of checking the
peer dialog will show that.

## Working out which piece is missing

From the `[vpn]` host, in this order. Each step narrows it to one cause:

```bash
sudo wg show wg0          # handshake present? transfer still 0 B received?
ping -c3 <instance tunnel IP>   # e.g. 10.99.0.1
ping -c3 1.1.1.1
curl -s --max-time 5 https://ifconfig.me
```

| result | cause |
| --- | --- |
| no handshake at all | not a firewall problem — see [docs/wireguard.md](wireguard.md) |
| handshake, but the instance's tunnel IP does not answer | no firewall rule on the WireGuard interface tab, or the existing rules are scoped to sources that do not include this peer |
| tunnel IP answers, `1.1.1.1` does not | outbound NAT does not cover the tunnel subnet |
| `1.1.1.1` answers, `curl` does not | not the firewall — DNS. `wg_dns` resolves through the tunnel, so it only starts working once the step above does |

`tcpdump -ni <wan-iface> udp port 51820` on the host splits "OPNsense never
replies" from "replies arrive and are rejected locally" in one command, if you
would rather start there.

## Doing this from the API

Not documented here yet. OPNsense has a REST API and none of the above needs
the UI; automating peer creation together with these rules is the item in
`TODO.md`.

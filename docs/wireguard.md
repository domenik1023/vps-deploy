# WireGuard hosts

Hosts in the `[vpn]` group are rented off-site and route their entire default
route through OPNsense over WireGuard, rather than through their own public
address. They run a kill switch so that a tunnel which drops takes their
internet with it rather than quietly falling back to the VPS's own public
address.

This is **not** an extension of the LAN. OPNsense treats each `[vpn]` host as
an isolated point-to-point peer with no route to the home LAN or to any other
peer — the tunnel reaches OPNsense and stops there. The point is to hide the
host from the network it is actually rented on: everything it originates
leaves as OPNsense's public address instead of its own.

SSH stays reachable from the internet on `ssh_port`. That is deliberate: it is
the way back in when the tunnel is broken, and restricting where it can be
reached from is a job for the network edge, not for this host.

> Everything on this page assumes the host is in `[vpn]` in the inventory.
> `wireguard_manage` derives from that, and nothing here runs otherwise.

## What the playbook does and does not do

It configures the client: installs WireGuard, writes
`/etc/wireguard/wg0.conf`, brings up `wg-quick@wg0`, installs the kill switch,
and refuses to finish until the tunnel has actually handshaked.

It does **not** create the peer on OPNsense. OPNsense has a real REST API that
could do this, but this playbook does not call it — the peer is registered
once, by hand in the OPNsense UI (or with a short one-off API call), and after
that this playbook never touches the server side again.

OPNsense never hands you a client private key — a peer entry only ever holds
the **client's public key**, and optionally a preshared key it generates
itself. So there is only one flow, unlike some WireGuard front-ends: the host
generates its own keypair, and you register the public half with OPNsense.
The private key is generated on the host that uses it and never travels.

## Setting one up

### 1. Create the peer on OPNsense

You need the host's own public key before this step, which means running the
playbook once first — see step 2, "the generated-key run." Once you have it,
in OPNsense: **VPN → WireGuard → Peers → + Add**.

| field | value |
| --- | --- |
| Public Key | this host's public key, from the generated-key run |
| Allowed IPs | this host's tunnel address, as a `/32` — e.g. `10.99.0.10/32` |
| Preshared Key | optional; generate one if you want it |

Keep Allowed IPs to the single `/32`. It is what tells OPNsense which source
address is legitimately this peer — anything wider would accept traffic
spoofing another peer's address, and would also make OPNsense try to route
that wider range back to this host.

After saving, edit the WireGuard **Instance** and add the new peer to it.

Two things to check, because both fail in ways that look like a broken tunnel
rather than a misconfigured one:

- the peer is **enabled**, and
- a firewall rule **on the WireGuard interface tab** (`opt1`/`wg0`, not WAN —
  OPNsense filters on the interface a packet *enters* the firewall on, and a
  peer's decrypted traffic enters there, exactly like the narrower admin/game
  peers this box also hosts) allows this peer's tunnel address out to any
  destination, and **Outbound NAT is Automatic** (or a manual rule covers the
  tunnel subnet). Unlike those narrower peers — an admin's own management
  access, a game server only ever *receiving* forwarded traffic — a
  full-tunnel `[vpn]` host needs to originate arbitrary outbound connections,
  and OPNsense's default policy on a WireGuard/OPT interface is to allow
  nothing at all. The Alloy play runs after the tunnel is up and fetches its
  release from GitHub through it, so a peer that can reach OPNsense but not
  the internet fails the run at Alloy rather than at WireGuard.

  Registering the peer above and adding this rule are two different pages,
  and only the second one complains if you forget it by *not existing* rather
  than by erroring — the tunnel still comes up and handshakes with no access
  at all. **[docs/opnsense-firewall.md](opnsense-firewall.md)** covers the
  rule shapes in use, why they go on the WireGuard interface tab rather than
  WAN, and how to tell which piece is missing from the host.

### 2. Write the host_vars file

Copy `host_vars/vpn-example.yml.example` to `host_vars/<name>.yml`, and set:

| what OPNsense calls it | host_vars |
| --- | --- |
| this host's own tunnel address (what you're about to register as Allowed IPs) | `wg_address` |
| a DNS resolver for the tunnel | `wg_dns` (a list) — a public one; there is no LAN resolver reachable from here |

Setting `wg_dns` pulls in a dependency worth knowing about: `wg-quick` applies
`DNS =` by piping into the `resolvconf` command, and does nothing else if it is
missing — it fails, and the interface never comes up. A minimal cloud image can
have no provider at all.

The role handles it, and does not assume which package to use — that varies by
release and image, and naming it wrong fails the run just as hard as naming
nothing. It checks whether the command already exists; only if it does not, it
runs `apt-cache policy` over `wg_resolvconf_packages` in order and installs the
first one apt can actually offer:

| package | where it applies |
| --- | --- |
| `systemd-resolved` | Ubuntu 23.04+ only. Before that, resolved is part of `systemd` and there is no such package. Preferred where it exists — it scopes the tunnel's DNS to the interface via `resolvectl`. |
| `openresolv` | the usual answer on 20.04/22.04. In universe. |
| `resolvconf` | the old Debian implementation, last resort. |

Then it asserts the command exists before going near the tunnel.

If the run stops here saying apt offered none of them, the host is on a release
or image where none is installable — enable universe, or add a package that
does exist there to `wg_resolvconf_packages`, or drop `wg_dns` and point the
host at a resolver another way.

Note that installing `systemd-resolved` takes over `/etc/resolv.conf` (a
symlink to its stub). The role will not do that to a host that already has a
working `resolvconf`, which is why the "already present" check comes first.

### 2. Write the host_vars file

Copy `host_vars/vpn-example.yml.example` to `host_vars/<name>.yml`, and set:

| what OPNsense calls it | host_vars |
| --- | --- |
| this host's own tunnel address (what you're about to register as Allowed IPs) | `wg_address` |
| a DNS resolver for the tunnel | `wg_dns` (a list) — a public one; there is no LAN resolver reachable from here |

Setting `wg_dns` pulls in a dependency worth knowing about: `wg-quick` applies
`DNS =` by piping into the `resolvconf` command, and does nothing else if it is
missing — it fails, and the interface never comes up. A minimal cloud image can
have no provider at all. The role installs one for you
(`wg_resolvconf_package`, default `systemd-resolved`, which on Ubuntu 24.04 is
the only package that `Provides: resolvconf` and ships
`/usr/sbin/resolvconf → resolvectl`), and then still asserts the command exists
before going near the tunnel.

Installing `systemd-resolved` takes over `/etc/resolv.conf`. On a host already
managing that file another way, set `wg_resolvconf_package: openresolv`, or
`""` to install nothing and have the run stop so you can decide by hand.
| OPNsense's **instance** public key | `wg_peer_public_key` |
| OPNsense's public host:port | `wg_peer_endpoint` |
| the preshared key, if you generated one on the peer | `wg_preshared_key` |

`wg_peer_public_key` is the trap worth naming: it is **OPNsense's** key, not
this host's. The two travel in opposite directions and are easy to swap —
both are base64 of the same shape, and a run prints one of them:

| value | where it belongs |
| --- | --- |
| OPNsense's **instance** public key (VPN → WireGuard → Instances) | `wg_peer_public_key` in this host's host_vars. Shared by every peer on that endpoint |
| this **host's** public key, printed by the generated-key run | the peer entry on OPNsense, as that peer's public key |

Putting the host's own key in `wg_peer_public_key` produces a tunnel that comes
up and never handshakes, and `sudo wg show wg0` shows no peer at all — the
kernel refuses a peer whose key is the interface's own. `tasks/tunnel.yml`
asserts against it before the config is written, and `tests/render-check.yml`
catches the wider family in CI by requiring every host on one endpoint to name
one peer key.

Also set:

```yaml
wg_generate_key: true
```

and leave `wg_private_key` out — this is the only path OPNsense supports. The
first run generates a keypair on the host, prints the public half, and
**stops before touching routing**:

```
TASK [Stop so the new public key can be registered on OPNsense]
fatal: [vpn-gwdg-01]: FAILED! => Generated a new WireGuard key for
vpn-gwdg-01. Add it to OPNsense as a peer (VPN: WireGuard: Peers), with public
key kR9v… and allowed address 10.99.0.10/32, then run this play again.
```

Take that public key back to step 1, register the peer, then run again. The
second run finds the key already there — `wg genkey` is guarded by `creates:`,
so re-running never rotates a key OPNsense has already learned — and carries
on to build the tunnel.

Nothing but the key file is written on that first pass. The tunnel is not
brought up, the default route does not move, and no rollback is armed.

`AllowedIPs` in the *rendered client config* is not the same setting as
OPNsense's peer Allowed IPs above, and is not transcribed from it — it comes
from `wg_allowed_ips`, which is `0.0.0.0/0` for every `[vpn]` host and should
stay that way. Anything narrower makes the kill switch a lie — traffic outside
the range would have no tunnel to take and would be dropped rather than
routed, which looks exactly like a broken tunnel.

#### The preshared key

Optional to *this playbook*: leave `wg_preshared_key` out and the
`PresharedKey` line is simply not rendered. It is **not** optional to
OPNsense — if the peer entry has one, the tunnel comes up and never
handshakes without it. Either supply it here or remove it from the peer on
OPNsense; there is no third option that works.

Since the private key is generated on the host and never leaves it, this is
the only secret in the file.

#### Vaulting, or not

Encrypting a secret in place keeps it out of the repository in readable form:

```bash
ansible-vault encrypt_string --name wg_preshared_key 'w1Rr…'
```

and paste what it prints into the host_vars file. Prefer per-host
`encrypt_string` over `group_vars/all/vault.yml`, so each host carries its own.

Writing it in plain text works and is a legitimate call for a private
repository — but it is worth being clear about what it costs, because the
tradeoff is not "safe versus convenient":

- A secret committed in plain text is in the git history permanently. Removing
  it later means rewriting history, and any copy already pushed elsewhere
  (a fork, a mirror, a CI cache, GitHub's own unreachable-object store) keeps
  it regardless.
- Migrating the repository to a self-hosted forge moves the *future*, not the
  past. The old remote keeps what it already has.
- Rotating a leaked preshared key means editing the peer on OPNsense and
  re-running.

So it is a reasonable choice for a key you are willing to rotate, and a poor
one for a key you are not. Nothing in the playbook enforces either way.

Prefer a bare IP address in `wg_peer_endpoint` if OPNsense's address is
static. A DNS name has to be resolved before the tunnel can come up, which is
why `wg_killswitch_allow_dns` defaults to on — see
[the kill switch](#what-the-kill-switch-blocks).

`ansible_host` stays the **public** address, not the tunnel address, by
default - the tunnel is built by the run, so on a first run it does not exist
yet. `vpn_ip` is an opt-in way to switch every run *after* the first onto the
tunnel address instead (see the commented-out example in
`vpn-example.yml.example`): set it once the tunnel is proven stable, and
`ansible_host` templates onto it automatically. There is no fallback if the
tunnel is down when you run the play - it just fails to connect - so this
trades the always-reachable public path for connecting only through the
tunnel. Direct SSH to the public address still works regardless of whether
`vpn_ip` is set, since the kill switch's SSH exception does not depend on it;
only `ansible-playbook` runs are affected.

### 3. Add it to the inventory and run

Add the name under `[vpn]` in `inventory`, then:

```bash
ansible-playbook tests/render-check.yml            # catches an incomplete host_vars
ansible-playbook main.yml -i inventory --ask-vault-pass --limit <name>
```

Have the provider's serial console open the first time. See
[if it goes wrong](#if-it-goes-wrong).

## How the routing works

`wg-quick` with `0.0.0.0/0` in `AllowedIPs` does not add a default route to the
main table. It puts one in a routing table of its own and adds two rules
matching this shape:

```
<p1>: from all lookup main suppress_prefixlength 0
<p2>: from all not fwmark 0xca6c lookup 51820
```

so everything that is not the tunnel's own traffic goes down the tunnel. That
breaks inbound connections: a packet arriving on the public interface is
answered by a reply that gets routed into the tunnel, and the session hangs the
instant the route moves.

**wg-quick does not pick a priority for those two rules at all - it adds them
with no `priority` argument, and the kernel decides.** The kernel's rule for
"no priority given" is `(the lowest priority currently in use) - 1`, computed
fresh each time. This repo spent three different fixed numbers on the kill
switch's own rule before finding that out: `32764`/`32765` (upstream's
documented default, never actually observed), `30000` (a real deployment
showed wg-quick landing one below it, at `29999`), then `100`. None of those
were wg-quick "picking" a number near ours by coincidence - each was wg-quick
undercutting whatever this repo's *own* rule already held, by exactly one,
because that rule existed before `wg-quick up` ran. This happened again live,
at the `100` default, on `vpn-gwdg-01`: `ip rule show` mid-incident read
wg-quick's rules at `98` and `99`, the kill switch's at `100` - one *above*,
meaning it was never reached. **A fixed priority for the kill switch's own
rule cannot work, at any value.**

The fix inverts the order. `wg-killswitch fix-route` runs *after*
`wg-quick up`, reads where wg-quick's rules actually landed from `ip rule
show`, and installs the SSH rule one below the real result:

```
ip rule add ipproto tcp sport <ssh_port> table main priority <lowest other rule - 1>
```

computed at run time, every time - `wg_killswitch_rule_priority` is gone,
there is nothing left to configure. This only works run *after* wg-quick, and
`roles/wireguard/tasks/tunnel.yml` calls it in the same remote command as
`systemctl start wg-quick@…`, immediately after, rather than as a separate
Ansible task - a second task would need its own SSH round trip on a
connection that may still be mid-transition. `wg-recover` and the
`Reload UFW` → kill switch restart handler chain both call it too, for the
same reason: restarting either unit deletes the SSH rule (`wg-killswitch off`
runs first either way) and nothing else puts it back.

**An earlier version of this used packet marking instead of a routing rule at
all** — `mangle PREROUTING` marked every connection arriving on the public
interface, `mangle OUTPUT` restored that mark onto replies, and the `ip rule`
matched the mark rather than the port. It was replaced because it interacted
badly with wg-quick's own fwmark: wg-quick's rule above is an *unmasked exact
match* against `0xca6c` (or whatever table number it actually picked), and
WireGuard's own re-keys and keepalives carry exactly that value — until the
connmark mechanism OR'd the kill switch's bit onto one of them, at which point
the value stopped being exactly `0xca6c` and wg-quick's rule swept the
tunnel's own traffic into itself. Masking the kill switch's bit stopped it
from *clearing* wg-quick's mark, but did nothing about *adding* one — either
way the value changes, and either way that rule's exact match fails. The
symptom was not an SSH hang: `wg show` reported one completed handshake and
then silence, forever, which reads like a problem on the WireGuard server and
is not one. The sport-based rule has no mark to combine with anything — it
reads the packet's own TCP header, so there is nothing left for wg-quick's
fwmark to collide with. That fixed one failure mode; the priority race above
was a second, independent one, found only once the first was already gone.
See CLAUDE.md's "WireGuard on `[vpn]` hosts" section for the fuller history.

`[vpn]` hosts also run with loose reverse path filtering
(`sysctl_rp_filter: 2`, in `group_vars/vpn.yml`). Strict mode drops inbound SSH
on the public interface as soon as the default route is the tunnel — the kernel
looks for a route back to that source, finds it points down `wg0`, and
discards the packet before any firewall rule is consulted.

### systemd-networkd will delete wg-quick's rules unless told not to

`systemd-networkd` tracks every `ip rule` and route, and by default deletes
any it did not create itself — on every reconciliation it runs for a managed
link. wg-quick's own two `ip rule` entries are exactly that kind of "foreign"
state. "Every reconciliation" is not rare: any veth going up or down - a
Docker container restarting - is enough to trigger one, and a single
crash-looping container does it repeatedly, fast.

Confirmed live on `vpn-gwdg-01`: a crash-looping container's veth churn
stripped both of wg-quick's rules within minutes of a reboot, while the
tunnel stayed up and kept handshaking the whole time. That is a silent, total
defeat of the kill switch - general traffic quietly stops going through the
tunnel at all and leaves the public interface in the clear, while `wg show`,
the interface state and the handshake age all keep looking healthy, because
none of them reflect routing policy.

The fix: `/etc/systemd/networkd.conf.d/99-wireguard-foreign-rules.conf` sets

```
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
```

and the play restarts `systemd-networkd` to apply it, before `wg-quick` or
anything else runs on the same play - not deferred to a handler, because it
has to be in effect before the very first `wg-quick up`, not merely by the
next run.

### A plain reboot needs its own trigger for fix-route

Only the play, `wg-recover` and the `Reload UFW` handler chain call
`wg-killswitch fix-route` - none of those run at a plain reboot, and
`wg-killswitch.service`'s own `on` deliberately does not install the SSH
routing rule (see above). Confirmed live: a reboot of `vpn-gwdg-01` left no
SSH `ip rule` at all, because nothing had asked for one since the tunnel came
up again.

`wg-quick@<iface>.service` gets its own drop-in with
`ExecStartPost=/usr/local/sbin/wg-killswitch fix-route`, which systemd runs
strictly after that unit's own `ExecStart` (`wg-quick up`) succeeds - on
every path that starts or restarts it, boot included, regardless of what else
happens to be running.

## What the kill switch blocks

`/usr/local/sbin/wg-killswitch`, run by `wg-killswitch.service`. Nothing leaves
the public interface except:

| allowed out | why |
| --- | --- |
| anything not on the public interface | loopback, `wg0`, the Docker bridges |
| `udp` to the endpoint's port | or the tunnel could never come up |
| `tcp --sport <ssh_port>` | replies to an inbound SSH session |
| DHCP / DHCPv6, and ICMPv6 | or the host loses its own address at lease expiry |
| `udp`/`tcp` port 53 | resolving `wg_peer_endpoint` with the tunnel down |
| `wg_killswitch_extra_allow` | whatever you add, scoped by you |

SSH is the only thing on a `[vpn]` host that accepts inbound internet
connections, so it is the only exception here. If that ever stops being true —
another service on one of these hosts needs to accept inbound connections and
reply back out the public interface — it needs the same treatment: a static
`ip rule` matched on its own port, the same shape as the SSH one, not a
reintroduction of connection marking (see above for why that goes wrong).

The SSH filter rule matches on source port and needs neither conntrack nor an
`ip rule` of its own to be *allowed* — it is a pure filter decision. What
actually gets the reply out the right *interface* is the `ip rule` described
above, matched on the same source port; the two use the same selector on
purpose; so a packet the filter rule allows is always one the routing decision
already sent the right way. This filter rule is also what still holds if the
routing rule is ever wrong for some other reason, and losing SSH means a trip
to the serial console.
`tests/render-check.yml` asserts it is present and ahead of the final `DROP`.

Containers are handled separately, in `DOCKER-USER`:

- `-i <wan> -j DROP` — nothing from the internet reaches a container. Published
  ports bind every address and Docker's `FORWARD` rules accept them regardless
  of ufw, so this is what actually closes them. Reach them over the tunnel.
- `-o <wan> -j DROP` — no container egress outside the tunnel.

`DOCKER-USER` rather than `ufw-before-forward`, because Docker's `FORWARD`
jumps run ahead of ufw's and ufw's forward chain never sees container traffic.

### It has to be re-applied after `ufw reload`

The kill switch's chains are jumped into from `OUTPUT` and `DOCKER-USER`, and
`ufw reload` is a stop/start whose `iptables-restore` flushes the builtins those
jumps live in. The `Reload UFW` handler restarts `wg-killswitch.service` for
exactly that reason — the same reason it restarts the CrowdSec bouncer. Adding
a `ufw_allow_rules` entry to a `[vpn]` host without that handler would silently
disarm the kill switch.

Both of those restarts are gated on `wireguard_manage` and `crowdsec_manage`
respectively, because `Reload UFW` also fires on hosts where neither service
exists.

## Containers and the tunnel's MTU

Symptom, and it does not look like an MTU problem: containers on a `[vpn]` host
appear to have no working internet. TCP connections open, `ping` works, DNS
works, and then anything with real payload hangs — `docker pull` stalls,
`apt update` sits there, HTTPS dies part-way through the certificate exchange.
The host itself is fine throughout, which is the clue.

The host is fine because the kernel picks the MSS it advertises from the
outgoing route's MTU. With `AllowedIPs = 0.0.0.0/0` that route is `wg0` at
`wg_mtu` (1420), so the host asks for 1380 without being told to. A container
cannot do that: it sits on a 1500-MTU bridge, advertises `MSS 1460` from its
own view of the world, and **the kernel never rewrites the MSS of traffic it
forwards** — a router is not supposed to.

The two directions then fail differently:

| direction | what happens | recovers? |
|---|---|---|
| container → internet | oversized frame reaches this host, does not fit `wg0`, host drops it and sends ICMP frag-needed back down the veth | yes — same kernel, no middlebox |
| internet → container | remote sends 1460-byte segments because the container asked for them; they die at OPNsense, which must send ICMP frag-needed back across the public internet to the remote | usually not — that ICMP is widely filtered |

So the second direction black-holes, and nothing ever tells the container to
ask for less.

`wg_mss_clamp` (on by default) fixes it with one rule in `mangle FORWARD` that
rewrites the MSS option on SYNs leaving the tunnel. The option means "do not
send me more than this", so the remote never emits a packet OPNsense cannot
carry. It is installed by the kill switch script, not by a `PostUp` line —
`wg-quick`'s hooks only run at tunnel up/down, while `ufw reload` flushes
`mangle FORWARD` at any time, and the kill switch is already restarted by the
`Reload UFW` handler.

Check it:

```bash
sudo iptables -t mangle -S FORWARD | grep MSS     # -o wg0 -j WG-KILLSWITCH-MSS
sudo iptables -t mangle -S WG-KILLSWITCH-MSS      # TCPMSS --clamp-mss-to-pmtu
sudo tcpdump -ni wg0 'tcp[tcpflags] & tcp-syn != 0' -vv   # MSS 1380 leaving, not 1460
docker run --rm alpine wget -qO- https://github.com >/dev/null && echo ok
```

If you are debugging this on a host that predates the clamp, the give-away is
that `curl -sS --max-filesize 1000 https://...` succeeds while a full fetch
hangs, and that lowering the container's own MTU
(`docker run --network=... --sysctl`, or a compose `driver_opts`) makes it work
— that is a workaround, not the fix, because it has to be repeated on every
network anyone creates.

## Verifying

```bash
sudo wg show                       # a recent handshake, and transfer in both directions
ip route get 1.1.1.1               # dev wg0 - if this names the public interface instead, wg-quick's own rules are gone (see systemd-networkd below), not just the kill switch's
ip rule                            # must show wg-quick's two rules (not fwmark / suppress_prefixlength) AND the sport rule one below them - missing wg-quick's own is the networkd issue, missing just the sport one is the fix-route issue
sudo iptables -S WG-KILLSWITCH-OUT # RETURNs, then one DROP at the end
sudo iptables -t mangle -S | grep KILLSWITCH
sudo sysctl net.ipv4.conf.all.rp_filter    # 2 on a [vpn] host
systemctl cat systemd-networkd.conf.d/99-wireguard-foreign-rules.conf   # ManageForeignRoutingPolicyRules=no, ManageForeignRoutes=no
systemctl cat wg-quick@wg0.service | grep ExecStartPost                 # the fix-route drop-in
```

From a container, that its egress goes through the tunnel and not around it:

```bash
docker run --rm alpine ping -c1 1.1.1.1    # works
sudo wg-quick down wg0
docker run --rm alpine ping -c1 1.1.1.1    # now fails — this is the point
# your SSH session should have survived that
sudo wg-quick up wg0
```

That last sequence is worth doing once on a new host. Fail-closed that has
never been tested is a hope, not a property.

Most of it can be checked without a host at all:

```bash
tests/killswitch-netns.sh
```

builds a public interface, a stand-in tunnel and the two `ip rule` entries
wg-quick installs, runs the real rendered script against them, and asks the
kernel where SSH's own traffic and an unmarked packet would each go. It runs
entirely inside `unshare -rn`, so it cannot touch your own routing, and it
skips itself where namespaces are unavailable.

## If it goes wrong

The play arms a rollback before it moves anything and cancels it only after the
host has answered *and* the tunnel has handshaked. If a run locks the host out,
it undoes itself within `wg_rollback_delay` (5 minutes by default):

```bash
systemctl disable --now wg-quick@wg0
systemctl disable --now wg-killswitch
/usr/local/sbin/wg-killswitch off
```

So the first thing to do is wait five minutes and try SSH again.

If it does not come back — the rollback timer was already cancelled by an
earlier successful run, or the box rebooted into a broken state — use the
provider's serial console and run those three commands by hand. They are the
whole rollback; there is no other state to unwind.

**The rollback disables both units — it does not just stop them.** That is
deliberate: retreating all the way to "disabled" is what stops a reboot from
re-applying the thing that locked the host out. It also means the recovery is
not `systemctl start wg-quick@wg0` (or `wg-quick up wg0` by hand). Either of
those brings the tunnel up, the host looks fine, and the boot symlink is never
recreated — so the host runs for as long as you like and then loses the tunnel
silently at the next reboot, with nothing in `journalctl -u wg-quick@wg0 -b` to
say why, because the unit was never asked to start.

**Recover with `wg-recover`, not raw `systemctl` commands:**

```bash
sudo wg-recover
```

It arms its own short rollback before touching anything, `restart`s (not
`start`s) both units, waits for a real handshake, and cancels the rollback
itself once one shows up — the same shape as the play's own bring-up, so a
manual recovery gets the same safety net. Do not substitute
`systemctl enable --now wg-killswitch`: it is `Type=oneshot,
RemainAfterExit=yes`, so if systemd still considers it *active* from an
earlier run — which disabling a unit does not change — `enable --now`/`start`
is a no-op that never re-runs the script. Anything that drifted since (a stray
`ip rule` added by hand while debugging, say) survives untouched, and you find
out that "fixing" it did nothing only once the tunnel breaks again.

A re-run of the play also fixes this — it sets `enabled: true` on both units —
and will say so plainly if it finds either one disabled, rather than
re-enabling it silently. But the play carries every other role's tasks with
it; `wg-recover` is the one-command version for when you just need the tunnel
back.

**`wg-tunnel-check.timer` catches the disabled state without anyone having to
notice a broken tunnel first.** Every `wg_tunnel_check_interval` (5 minutes by
default) it checks whether both units are enabled and active, and is silent
when they are. When one is not, it logs to the journal — which Alloy already
ships in full, so nothing in `roles/alloy` needed to change — and exits
non-zero, which is what makes `wg-tunnel-check.service` show up as failed in
`node_systemd_unit_state{name="wg-tunnel-check.service"}`: the systemd
collector is already enabled in `config.alloy.j2`, so this needs no exporter
of its own. Alert on that metric, or on the journal line, and a rolled-back
tunnel gets noticed within one interval instead of at the next scheduled
reboot.

Common causes, in the order they are worth checking:

| symptom | cause |
| --- | --- |
| play fails at "must have handshaked" | the peer is not registered or is disabled on OPNsense; `wg_preshared_key` does not match; OPNsense's WAN does not allow the tunnel's UDP port in |
| `sudo wg show wg0` lists the interface but **no `peer:` block at all** | `wg_peer_public_key` holds this host's own key. WireGuard will not accept a peer whose public key is the interface's own, so it is dropped and the tunnel runs with no peer — every packet vanishes and it never handshakes. The play now refuses this before writing the config; a host configured before that check existed shows it this way |
| tunnel is up, nothing routes | OPNsense's outbound NAT does not cover the tunnel subnet, or no rule on the WireGuard interface tab permits this peer's traffic out |
| SSH dies the moment the route moves | check `ip rule show \| grep sport` for a rule matching `ssh_port`, and that its priority number is LOWER than wg-quick's two rules (`not fwmark …` / `suppress_prefixlength 0`) - if it's missing, or higher, `fix-route` either didn't run or ran before `wg-quick up`; run `sudo /usr/local/sbin/wg-killswitch fix-route` by hand to fix it immediately, then check why it didn't happen automatically. Also confirm `sysctl_rp_filter` is 2 |
| `ip rule` shows a rule matching the SSH port that's higher (later) than wg-quick's own | `fix-route` computed against a stale picture - most likely it ran once, then something restarted wg-quick without calling `fix-route` again (wg-quick's rules moved, ours didn't follow). `sudo /usr/local/sbin/wg-killswitch fix-route` re-derives it against current state; if this recurs, something is restarting `wg-quick@<iface>` outside the paths that already call `fix-route` (the play, `wg-recover`) |
| `wg show` reports exactly one completed handshake and then nothing, ever — no rekeys, no keepalives, no traffic | the signature of the old CONNMARK-based mechanism, if a host is somehow still running a script from before it was replaced (see "How the routing works" above). Confirm with `iptables -t mangle -S`: if `WG-KILLSWITCH-MARK`/`WG-KILLSWITCH-RESTORE` still exist, the host has an outdated script — re-run the play (or `wg-recover`) to deploy the current one, which also cleans those chains up. This reads exactly like a problem on the WireGuard server and is not one |
| tunnel up, handshaking fine, traffic just isn't going through it — `ping`/anything general fails or goes straight out the public interface instead | `ip rule show` is probably missing wg-quick's own two rules (`not fwmark …` / `suppress_prefixlength 0`), not just the kill switch's. `systemd-networkd` deletes any `ip rule`/route it did not create itself on every link reconciliation — any container restarting is enough to trigger one — unless told not to; confirm `systemctl cat systemd-networkd.conf.d/99-wireguard-foreign-rules.conf` shows `ManageForeignRoutingPolicyRules=no` and `ManageForeignRoutes=no`, and that `systemctl status systemd-networkd` shows it active since that config was written. If the override is missing or was never applied, the kill switch's whole point — forcing everything through the tunnel — is silently not happening, while every other signal (interface state, handshake age, transfer counters) keeps looking healthy, because none of them reflect routing policy at all. Re-run the play to install and apply it |
| after a reboot, SSH to the public address hangs even though `wg show` looks fine | nothing calls `wg-killswitch fix-route` on a plain reboot except the drop-in on `wg-quick@<iface>.service` (`ExecStartPost=`) — if that drop-in is missing (`systemctl cat wg-quick@<iface>.service` should show it under `# /etc/systemd/system/wg-quick@<iface>.service.d/override.conf`), re-run the play to install it. Until then, `sudo /usr/local/sbin/wg-killswitch fix-route` by hand restores it immediately |
| `journalctl -b` shows `Found ordering cycle: ... after wg-killswitch.service/start after docker.service/start ...` | an outdated `wg-killswitch.service` still combining `Before=network-pre.target` with `After=docker.service` — contradictory, and systemd silently drops one of the two on every boot rather than erroring. Re-run the play to deploy the current unit file, which drops `After=docker.service` (safe: `DOCKER-USER` is never flushed by dockerd after its first creation, so nothing here actually depended on strict Docker ordering) |
| Alloy fails to install on the first run | same as "nothing routes": its release is fetched through the tunnel |
| telemetry never arrives | `wg_dns` is not set, so the ingest hostname does not resolve — see `group_vars/vpn.yml` |
| host loses its address after a day | DHCP is being blocked; check the kill switch's DHCP exceptions survived an edit |

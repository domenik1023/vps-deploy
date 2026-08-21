# WireGuard hosts

Hosts in the `[vpn]` group are rented off-site but belong to the LAN. They join
it over WireGuard, take their default route from the tunnel, and run a kill
switch so that a tunnel which drops takes their internet with it rather than
quietly falling back to the VPS's own public address.

They exist to run containers that want more RAM than the LAN boxes have and do
not care about a few milliseconds — an extension of the LAN, not a separate
site.

SSH stays reachable from the internet on `ssh_port`. That is deliberate: it is
the way back in when the tunnel is broken, and restricting where it can be
reached from is a job for the network edge, not for this host.

> Everything on this page assumes the host is in `[vpn]` in the inventory.
> `wireguard_manage` derives from that, and nothing here runs otherwise.

## What the playbook does and does not do

It configures the client: installs WireGuard, writes
`/etc/wireguard/wg0.conf`, brings up `wg-quick@wg0`, installs the kill switch,
and refuses to finish until the tunnel has actually handshaked.

It does **not** create the peer on the UniFi side. UniFi Network's WireGuard
VPN server has no supported API for client management — only the controller's
private REST endpoints, which need a local account, CSRF handling, and change
shape between Network releases. Create the client in the UDM UI; the steps
below carry its details into the inventory.

**Which half of the keypair you have to move depends on your UniFi version**,
and they differ:

- Some hand you a **finished client config**, private key included. Transcribe
  it — [flow A](#a-the-udm-gave-you-a-private-key).
- Others give you only the **server's public key and a preshared key**, and
  expect a client public key back. Then the host generates its own keypair and
  you paste the public half into the UDM —
  [flow B](#b-the-udm-wants-a-public-key-from-you).

Flow B is the ordinary WireGuard model and the better one: the private key is
generated on the host that uses it and never travels.

## Setting one up

### 1. Create the client on the UDM

In the UniFi Network application, under the WireGuard VPN server, add a client
and download or copy its configuration. It looks like this:

```ini
[Interface]
PrivateKey = qK5m…
Address = 10.0.2.11/32
DNS = 192.168.2.1

[Peer]
PublicKey = 8Yt2…
PresharedKey = w1Rr…
Endpoint = vpn.d1023.de:51820
AllowedIPs = 0.0.0.0/0
```

Two things to check while you are there, because both fail in ways that look
like a broken tunnel rather than a misconfigured one:

- the client is **enabled**, and
- VPN clients are allowed to reach the internet. The Alloy play runs *after*
  the tunnel is up and fetches its release from GitHub through it, so a peer
  that can reach the LAN but not the internet fails the run at Alloy rather
  than at WireGuard.

### 2. Write the host_vars file

Copy `host_vars/vpn-example.yml.example` to `host_vars/<name>.yml`. Both flows
need these four, whatever the UDM called them:

| what the UDM shows | host_vars |
| --- | --- |
| the client's tunnel address | `wg_address` |
| the DNS server for the tunnel | `wg_dns` (a list) |
| the **server's** public key | `wg_peer_public_key` |
| the server's host:port | `wg_peer_endpoint` |
| the preshared key, if there is one | `wg_preshared_key` |

`wg_peer_public_key` is the trap worth naming: it is the *server's* key, not
this host's. Putting the host's own public key there produces a tunnel that
comes up and never handshakes.

#### A: the UDM gave you a private key

Add it as `wg_private_key`, from the client config's `[Interface] PrivateKey`.

#### B: the UDM wants a public key from you

You have the server's public key, possibly a preshared key, and nothing else.
Set:

```yaml
wg_generate_key: true
```

and leave `wg_private_key` out. The first run generates a keypair on the host,
prints the public half, and **stops before touching routing**:

```
TASK [Stop so the new public key can be registered on the server]
fatal: [vpn-gwdg-01]: FAILED! => Generated a new WireGuard key for
vpn-gwdg-01. Add it to the WireGuard server as a client, with public key
kR9v… and allowed address 192.168.9.20/32, then run this play again.
```

Paste that public key into the UDM as the client, with this host's tunnel
address as its allowed address, then run again. The second run finds the key
already there — `wg genkey` is guarded by `creates:`, so re-running never
rotates a key the server has learned — and carries on to build the tunnel.

Nothing but the key file is written on that first pass. The tunnel is not
brought up, the default route does not move, and no rollback is armed.

`AllowedIPs` is not transcribed: it comes from `wg_allowed_ips`, which is
`0.0.0.0/0` for every `[vpn]` host and should stay that way. Anything narrower
makes the kill switch a lie — traffic outside the range would have no tunnel to
take and would be dropped rather than routed, which looks exactly like a broken
tunnel.

#### The preshared key

Optional to *this playbook*: leave `wg_preshared_key` out and the `PresharedKey`
line is simply not rendered. It is **not** optional to the server — if the UDM
issued one for this client, the tunnel comes up and never handshakes without
it. Either supply it here or remove it on the UDM side; there is no third
option that works.

Under flow B that is the only secret in the file, since the private key is
generated on the host and never leaves it.

#### Vaulting, or not

Encrypting a secret in place keeps it out of the repository in readable form:

```bash
ansible-vault encrypt_string --name wg_preshared_key 'w1Rr…'
ansible-vault encrypt_string --name wg_private_key   'qK5m…'   # flow A only
```

and paste what each prints into the host_vars file. Prefer per-host
`encrypt_string` over `group_vars/all/vault.yml`, so each host carries its own.

Writing them in plain text works and is a legitimate call for a private
repository — but it is worth being clear about what it costs, because the
tradeoff is not "safe versus convenient":

- A secret committed in plain text is in the git history permanently. Removing
  it later means rewriting history, and any copy already pushed elsewhere
  (a fork, a mirror, a CI cache, GitHub's own unreachable-object store) keeps
  it regardless.
- Migrating the repository to a self-hosted forge moves the *future*, not the
  past. The old remote keeps what it already has.
- Rotating a leaked preshared key means editing the client on the UDM and
  re-running; rotating a leaked private key means re-registering the peer.

So it is a reasonable choice for a key you are willing to rotate, and a poor
one for a key you are not. Nothing in the playbook enforces either way.

Prefer a bare IP address in `wg_peer_endpoint` if the home connection has a
static one. A DNS name has to be resolved before the tunnel can come up, which
is why `wg_killswitch_allow_dns` defaults to on — see
[the kill switch](#what-the-kill-switch-blocks).

`ansible_host` stays the **public** address, not the tunnel address. The tunnel
is built by the run, so on a first run it does not exist yet.

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
main table. It puts one in a routing table of its own and adds two rules:

```
32764: from all lookup main suppress_prefixlength 0
32765: from all not fwmark 0xca6c lookup 51820
```

so everything that is not the tunnel's own traffic goes down the tunnel. That
breaks inbound connections: a packet arriving on the public interface is
answered by a reply that gets routed into the tunnel, and the session hangs the
instant the route moves.

The fix is a mark of our own. The kill switch script:

- marks every connection arriving on the public interface, in `mangle
  PREROUTING`;
- restores that mark on outbound packets, in `mangle OUTPUT`;
- adds `ip rule fwmark <mark> table main priority 30000`, which is consulted
  before wg-quick's rules and sends those packets back out the public
  interface.

The mark is a single bit (`wg_killswitch_mark`, `0x40000`) used as its own mask.
That matters: `wg-quick` sets its own fwmark on the encrypted packets it sends,
and an unmasked `CONNMARK --restore-mark` would clear it, routing the tunnel's
own traffic back into the tunnel.

It is **not** wg-quick's fwmark, and must not be set to it. wg-quick derives
that from the first free routing table it finds counting up from 51820, at run
time, and overrides whatever `FwMark` the config file asks for — so it is not a
number this repo can know. `wg.conf.j2` deliberately does not set `FwMark`.

`[vpn]` hosts also run with loose reverse path filtering
(`sysctl_rp_filter: 2`, in `group_vars/vpn.yml`). Strict mode drops inbound SSH
on the public interface as soon as the default route is the tunnel — the kernel
looks for a route back to that source, finds it points down `wg0`, and discards
the packet before any firewall rule is consulted.

## What the kill switch blocks

`/usr/local/sbin/wg-killswitch`, run by `wg-killswitch.service`. Nothing leaves
the public interface except:

| allowed out | why |
| --- | --- |
| anything not on the public interface | loopback, `wg0`, the Docker bridges |
| `udp` to the endpoint's port | or the tunnel could never come up |
| `tcp --sport <ssh_port>` | replies to an inbound SSH session |
| anything carrying the connmark | replies to anything else reached from outside |
| DHCP / DHCPv6, and ICMPv6 | or the host loses its own address at lease expiry |
| `udp`/`tcp` port 53 | resolving `wg_peer_endpoint` with the tunnel down |
| `wg_killswitch_extra_allow` | whatever you add, scoped by you |

The SSH rule matches on source port and needs neither conntrack nor an `ip
rule`. That is the point of it: it is what still holds if the mangle half is
wrong, and losing SSH means a trip to the serial console.
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

## Verifying

```bash
sudo wg show                       # a recent handshake, and transfer in both directions
ip route get 1.1.1.1               # dev wg0
ip rule                            # the 30000 fwmark rule, above wg-quick's 32764/32765
sudo iptables -S WG-KILLSWITCH-OUT # RETURNs, then one DROP at the end
sudo iptables -t mangle -S | grep KILLSWITCH
sudo sysctl net.ipv4.conf.all.rp_filter    # 2 on a [vpn] host
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
kernel where a marked reply and an unmarked packet would each go. It runs
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

Common causes, in the order they are worth checking:

| symptom | cause |
| --- | --- |
| play fails at "must have handshaked" | the client is not registered or is disabled on the UDM; `wg_peer_public_key` is this host's key rather than the server's; `wg_preshared_key` does not match; the server's UDP port is not reachable |
| tunnel is up, nothing routes | the UDM is not routing this peer to the internet |
| SSH dies the moment the route moves | the mangle rules did not install — check `iptables -t mangle -S` and `ip rule`, and that `sysctl_rp_filter` is 2 |
| Alloy fails to install on the first run | same as "nothing routes": its release is fetched through the tunnel |
| telemetry never arrives | `wg_dns` is not set, so `ingest.net.d1023.de` does not resolve — see `group_vars/vpn.yml` |
| host loses its address after a day | DHCP is being blocked; check the kill switch's DHCP exceptions survived an edit |

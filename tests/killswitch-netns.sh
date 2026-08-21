#!/bin/bash
# Exercise the WireGuard kill switch against a real kernel, without a VPS.
#
#   tests/killswitch-netns.sh
#
# tests/render-check.yml can only read the rendered text: that the rules are in
# the right order, that the script parses as bash. What it cannot tell you is
# whether the kernel agrees - whether `ip rule` actually sends a marked reply
# out of the public interface while everything else goes down the tunnel. That
# is the property the whole design rests on, and getting it wrong costs a trip
# to the provider's serial console.
#
# So build the situation in a network namespace: a public interface with a
# default route, a stand-in tunnel, and the two `ip rule` entries wg-quick
# installs for AllowedIPs = 0.0.0.0/0. Then run the real rendered script and
# ask the kernel where packets would go.
#
# Everything happens inside `unshare -rn`, so nothing here touches the host's
# own firewall or routing.
#
# Skips rather than fails where it cannot run - an unprivileged container, a
# kernel without veth - so it is safe in CI.
set -euo pipefail

cd "$(dirname "$0")/.."

WAN=eth0
WAN_ADDR=198.51.100.10
WAN_GW=198.51.100.1
TUN=wg0
TUN_ADDR=10.0.2.11
WG_TABLE=51820
MARK=0x40000

skip() { echo "SKIP: $*"; exit 0; }

command -v ip >/dev/null || skip "iproute2 not installed"
command -v iptables >/dev/null || skip "iptables not installed"
command -v ansible-playbook >/dev/null || skip "ansible not installed"
unshare -rn true 2>/dev/null || skip "cannot create a network namespace here"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Render the real template, with the real defaults, exactly as a [vpn] host
# would get it.
cat > "$work/render.yml" <<YAML
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files:
    - $PWD/roles/baseline/defaults/main/10_ssh.yml
    - $PWD/roles/baseline/defaults/main/60_wireguard.yml
  vars:
    wg_wan_interface_resolved: $WAN
    wg_peer_endpoint: "vpn.example.com:51820"
  tasks:
    - copy:
        content: "{{ lookup('template', '$PWD/roles/baseline/templates/wg-killswitch.j2') }}"
        dest: $work/wg-killswitch
        mode: "0755"
YAML
ansible-playbook "$work/render.yml" >/dev/null

fail=0
check() { # description, expected substring, actual
    if [[ "$3" == *"$2"* ]]; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1"
        echo "        expected to contain: $2"
        echo "        got:                 ${3:-<nothing - the script died before this point>}"
        fail=1
    fi
}

echo "kill switch, in a network namespace:"

out=$(unshare -rn bash -c "
set -e
ip link set lo up
ip link add $WAN type veth peer name ${WAN}p
ip addr add $WAN_ADDR/24 dev $WAN
ip link set $WAN up
ip route add default via $WAN_GW dev $WAN

ip link add $TUN type veth peer name ${TUN}p
ip addr add $TUN_ADDR/32 dev $TUN
ip link set $TUN up

# What wg-quick installs for AllowedIPs = 0.0.0.0/0.
ip route add default dev $TUN table $WG_TABLE
ip rule add not fwmark $WG_TABLE table $WG_TABLE priority 32765
ip rule add table main suppress_prefixlength 0 priority 32764

# From here on the point is to observe failures, not to stop at the first one:
# a run that aborts here reports nothing at all, which is how a broken kill
# switch would look exactly like a broken test.
set +e

$work/wg-killswitch on >/dev/null 2>&1; echo \"ON_EXIT=\$?\"
echo \"LAST_RULE=\$(iptables -S WG-KILLSWITCH-OUT 2>/dev/null | tail -1)\"
echo \"SSH_RULE=\$(iptables -S WG-KILLSWITCH-OUT 2>/dev/null | grep -c -- '--sport 22822')\"
echo \"UNMARKED=\$(ip route get 203.0.113.99 | head -1)\"
echo \"MARKED=\$(ip route get 203.0.113.99 mark $MARK | head -1)\"

$work/wg-killswitch off >/dev/null 2>&1; echo \"OFF_EXIT=\$?\"
echo \"LEFTOVER_RULES=\$(iptables -S | grep -c KILLSWITCH || true)\"
echo \"LEFTOVER_IPRULE=\$(ip rule | grep -c $MARK || true)\"
" 2>&1)

# Never fails: a missing line means the namespace script died before printing
# it, and the check that reads it should say so rather than taking the whole
# test down with it.
get() { grep "^$1=" <<<"$out" | cut -d= -f2- || true; }

# The script has to succeed on a host with no IPv6, which is where it used to
# abort half way through under `set -e`, leaving the unit failed and one family
# unprotected.
check "installs cleanly and exits 0"          "0"    "$(get ON_EXIT)"
check "SSH exception is present"              "1"    "$(get SSH_RULE)"
check "the chain ends in DROP"                "-j DROP" "$(get LAST_RULE)"

# The property the design rests on.
check "unmarked traffic takes the tunnel"     "dev $TUN"  "$(get UNMARKED)"
check "a marked reply takes the public link"  "dev $WAN"  "$(get MARKED)"

check "removes cleanly and exits 0"           "0"    "$(get OFF_EXIT)"
check "leaves no iptables rules behind"       "0"    "$(get LEFTOVER_RULES)"
check "leaves no ip rule behind"              "0"    "$(get LEFTOVER_IPRULE)"

if [ "$fail" -ne 0 ]; then
    echo
    echo "raw output:"
    printf "%s\n" "${out//$'\n'/$'\n'  }"
    exit 1
fi
echo "kill switch behaves as designed."

#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

dns="$ROOT/bin/omarchy-dns"
helper="$ROOT/install/helpers/dns.sh"
hardware_network="$ROOT/install/hardware/network.sh"

! grep -F 'systemd-networkd' "$dns" >/dev/null || fail "omarchy-dns no longer restarts systemd-networkd"
grep -F 'source "${OMARCHY_PATH:-/usr/share/omarchy}/install/helpers/dns.sh"' "$dns" >/dev/null
grep -F 'NetworkManager/conf.d/20-omarchy-dns.conf' "$helper" >/dev/null
grep -F '[global-dns-domain-*]' "$helper" >/dev/null
grep -F 'ipv4.ignore-auto-dns yes' "$helper" >/dev/null
grep -F 'ipv4.ignore-auto-dns no' "$helper" >/dev/null
grep -F 'nmcli device reapply' "$helper" >/dev/null
grep -F 'nmcli general reload conf' "$helper" >/dev/null
grep -F 'nmcli general reload dns-full' "$helper" >/dev/null
if grep -F 'nmcli general reload conf,dns-full' "$helper" >/dev/null; then
  fail "omarchy-dns must not push DNS before reapplying active profiles"
fi
pass "omarchy-dns configures DNS through NetworkManager"

grep -F 'systemd-networkd.service' "$hardware_network" >/dev/null
grep -F 'systemd-networkd.socket' "$hardware_network" >/dev/null
grep -F '20-wlan.network' "$hardware_network" >/dev/null
grep -F 'omarchy-networkd-retired' "$hardware_network" >/dev/null
pass "hardware setup retires archinstall networkd state"

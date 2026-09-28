#!/bin/bash
#
# Family DNS: provider detection, the child lock, parent-dns status, the
# dispatcher hook, and the resolved.conf Families/Security strings. Live
# NetworkManager and resolved are never touched; nmcli and systemctl are
# stubbed on PATH.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

dns="$ROOT/bin/omarchy-dns"
parent_dns="$ROOT/bin/omarchy-parent-dns"
helper="$ROOT/install/helpers/dns.sh"

export PATH="$ROOT/bin:$PATH"

grep -q '^# omarchy:summary=' "$parent_dns" || fail "omarchy-parent-dns carries command metadata"
grep -q '^# omarchy:requires-sudo=true' "$parent_dns" || fail "omarchy-parent-dns is marked as needing sudo"
help_output=$(OMARCHY_PATH="$ROOT" bash "$parent_dns" --help)
[[ $help_output == *"omarchy-parent dns"* && $help_output == *"on"* && $help_output == *"security"* ]] ||
  fail "omarchy-parent-dns --help prints usage without elevating"
pass "omarchy-parent-dns is a documented parent feature command"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export OMARCHY_PATH="$ROOT"
export OMARCHY_PROFILE_FILE="$test_tmp/profile"
export OMARCHY_PARENT_CONF="$test_tmp/parent.conf"
export OMARCHY_NM_DNS_CONF="$test_tmp/20-omarchy-dns.conf"
export OMARCHY_RESOLVED_CONF="$test_tmp/resolved.conf"

source "$helper"

printf '[global-dns-domain-*]\nservers=1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003\n' >"$NM_DNS_CONF"
[[ $(dns_detect_provider) == "Families" ]] || fail "1.1.1.3 is Families, not Cloudflare"
printf 'DNS=1.1.1.3#family.cloudflare-dns.com 1.0.0.3#family.cloudflare-dns.com\n' >"$RESOLVED_CONF"
rm -f "$NM_DNS_CONF"
[[ $(dns_detect_provider) == "Families" ]] || fail "family.cloudflare-dns.com is Families even though it contains cloudflare-dns.com"

printf 'DNS=1.1.1.2#security.cloudflare-dns.com 1.0.0.2#security.cloudflare-dns.com\n' >"$RESOLVED_CONF"
[[ $(dns_detect_provider) == "Security" ]] || fail "security.cloudflare-dns.com is Security, not Cloudflare"

printf 'DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com\n' >"$RESOLVED_CONF"
[[ $(dns_detect_provider) == "Cloudflare" ]] || fail "cloudflare-dns.com without family/security is Cloudflare"

: >"$RESOLVED_CONF"
[[ $(dns_detect_provider) == "DHCP" ]] || fail "empty resolved DNS is DHCP"
pass "detection matches Families and Security before Cloudflare"

printf 'DNS=1.1.1.30#example.test 11.1.1.3#example.test\n' >"$RESOLVED_CONF"
[[ $(dns_detect_provider) == "Custom" ]] || fail "1.1.1.30 and 11.1.1.3 must not match Families as a substring"
printf 'DNS=1.1.1.3#family.cloudflare-dns.com\n' >"$RESOLVED_CONF"
[[ $(dns_detect_provider) == "Families" ]] || fail "a whole 1.1.1.3 token is still Families"
pass "detection matches whole DNS tokens only"

eval "$(sed -n '/^split_dns_servers() {/,/^}/p' "$dns")"
ipv4_dns="" ipv6_dns=""
split_dns_servers 'dns+tls://9.9.9.9#dns.quad9.net,1.1.1.1'
[[ $ipv4_dns == "9.9.9.9 1.1.1.1" && -z $ipv6_dns ]] ||
  fail "split_dns_servers strips dns+tls:// from the cleaned token" "ipv4=$ipv4_dns ipv6=$ipv6_dns"
ipv4_dns="" ipv6_dns=""
split_dns_servers 'dns+udp://1.0.0.1,8.8.8.8'
[[ $ipv4_dns == "1.0.0.1 8.8.8.8" && -z $ipv6_dns ]] ||
  fail "split_dns_servers strips dns+udp:// from the cleaned token" "ipv4=$ipv4_dns ipv6=$ipv6_dns"
pass "split_dns_servers keeps stripping after the first protocol prefix"

printf 'default\n' >"$OMARCHY_PROFILE_FILE"
[[ $(dns_mode) == "off" ]] || fail "a default install with no dns= is unlocked"
if dns_locked; then
  fail "a default install is not locked"
fi

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
[[ $(dns_mode) == "on" ]] || fail "an unset dns= on a child install defaults to on"
dns_locked || fail "an unset dns= on a child install is locked"
printf 'dns=off\n' >"$OMARCHY_PARENT_CONF"
if dns_locked; then
  fail "dns=off unlocks a child install"
fi
printf 'dns=security\n' >"$OMARCHY_PARENT_CONF"
dns_locked || fail "dns=security keeps a child install locked"
pass "the child lock defaults to on and honors dns=off"

status=$(OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
  OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" OMARCHY_NM_DNS_CONF="$NM_DNS_CONF" \
  OMARCHY_RESOLVED_CONF="$RESOLVED_CONF" bash "$parent_dns" status)
[[ $status == *$'\nlocked=yes\n'* || $status == *$'\nlocked=yes' ]] ||
  fail "omarchy-parent-dns status reports locked=yes" "$status"
[[ $status == *mode=security* ]] || fail "omarchy-parent-dns status reports the saved mode" "$status"
locked_out=$(OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
  OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" bash "$parent_dns" locked) ||
  fail "omarchy-parent-dns locked exits 0 when locked"
[[ $locked_out == yes ]] || fail "omarchy-parent-dns locked prints yes when locked" "$locked_out"
locked_out=$(OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
  OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" PATH="/usr/bin:/bin" bash "$parent_dns" locked) ||
  fail "omarchy-parent-dns locked must not depend on omarchy-profile-child being on PATH"
[[ $locked_out == yes ]] || fail "omarchy-parent-dns locked prints yes without omarchy-profile-child on PATH" "$locked_out"
pass "omarchy-parent-dns status and locked answer without a password"

[[ $(dns_provider_from_arg families) == "Families" ]] || fail "families maps to Families"
[[ $(dns_provider_from_arg Security) == "Security" ]] || fail "Security maps to Security"
[[ $(dns_provider_dot Families) == "yes" ]] || fail "Families uses strict DNS-over-TLS"
[[ $(dns_provider_dot Security) == "yes" ]] || fail "Security uses strict DNS-over-TLS"
[[ $(dns_provider_dot Cloudflare) == "opportunistic" ]] || fail "Cloudflare stays opportunistic"
[[ $(dns_provider_resolved Families) == *"1.1.1.3#family.cloudflare-dns.com"* ]] ||
  fail "Families resolved line pins family.cloudflare-dns.com"
[[ $(dns_provider_resolved Families) == *"1.0.0.3#family.cloudflare-dns.com"* ]] ||
  fail "Families resolved line includes the second family IPv4"
[[ $(dns_provider_resolved Families) == *"2606:4700:4700::1113#family.cloudflare-dns.com"* ]] ||
  fail "Families resolved line includes family IPv6"
[[ $(dns_provider_resolved Families) == *"2606:4700:4700::1003#family.cloudflare-dns.com"* ]] ||
  fail "Families resolved line includes the second family IPv6"
[[ $(dns_provider_resolved Security) == *"1.1.1.2#security.cloudflare-dns.com"* ]] ||
  fail "Security resolved line pins security.cloudflare-dns.com"
[[ $(dns_provider_resolved Security) == *"1.0.0.2#security.cloudflare-dns.com"* ]] ||
  fail "Security resolved line includes the second security IPv4"
[[ $(dns_provider_nm_servers Families) == *"1.1.1.3"* && $(dns_provider_nm_servers Families) == *"1.0.0.3"* ]] ||
  fail "Families NM servers include both family IPv4 addresses"
[[ $(dns_provider_ipv6 Security) == *"2606:4700:4700::1112"* && $(dns_provider_ipv6 Security) == *"2606:4700:4700::1002"* ]] ||
  fail "Security includes both malware IPv6 addresses"
pass "Families and Security provider strings match Cloudflare's published anycast"

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
dns_omit_fallback Cloudflare || fail "a child install omits the Quad9 fallback for every provider"
dns_omit_fallback Families || fail "Families omits the Quad9 fallback"
printf 'default\n' >"$OMARCHY_PROFILE_FILE"
if dns_omit_fallback Cloudflare; then
  fail "an adult Cloudflare setting still has the Quad9 fallback"
fi
dns_omit_fallback Families || fail "adult Families still omits the unfiltered fallback"
[[ $(dns_provider_fallback Families) == "$(dns_provider_resolved Families)" ]] ||
  fail "Families fallback must mirror the filtered resolver line"
[[ $(dns_provider_fallback Security) == "$(dns_provider_resolved Security)" ]] ||
  fail "Security fallback must mirror the filtered resolver line"
[[ $(dns_provider_fallback Cloudflare) == "$QUAD9_FALLBACK" ]] ||
  fail "adult Cloudflare still uses the Quad9 fallback"
pass "filtered modes pin FallbackDNS to the same provider; adults keep Quad9"

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
rm -f "$OMARCHY_PARENT_CONF"
eval "$(sed -n '/^document_dns() {/,/^}/p' "$parent_dns")"
document_dns
grep -Fq 'stops enforcing a resolver' "$OMARCHY_PARENT_CONF" ||
  fail "parent.conf documents that off stops enforcing a resolver"
grep -Fq 'kid is not in wheel' "$OMARCHY_PARENT_CONF" ||
  fail "parent.conf documents that changing provider still needs the parent password"
pass "document_dns describes off as stop-enforcing, not a kid-unlocked picker"

grep -Fq 'run_logged "$OMARCHY_INSTALL/config/dns.sh"' "$ROOT/install/config/all.sh" || fail "family DNS is wired into system setup after the parental posture"
grep -Fq 'omarchy-parent-dns on' "$ROOT/install/config/dns.sh" || fail "the install leaf turns family DNS on"
grep -Fq 'omarchy-parent-dns on' "$ROOT/bin/omarchy-provision-owner" || fail "deferred child provisioning turns family DNS on"
# The lock itself is written at install and first boot. The later egress-filter
# + DoH-pin migration reapplies that lock on machines that already had it.
grep -Fq 'family DNS egress filter' "$ROOT/migrations/1790549305.sh" ||
  fail "existing child installs migrate onto the egress filter and DoH pin"
pass "parent-dns apply is wired at install, first boot, and the filter migration"

menu="$ROOT/default/omarchy/omarchy-menu.jsonc"
grep -q '"setup.network.dns.families"' "$menu" || fail "the menu offers Families"
grep -q '"setup.network.dns.security"' "$menu" || fail "the menu offers Security"
grep -q 'omarchy-parent-dns locked' "$menu" || fail "the DNS picker hides on a locked child install"
grep -q '"setup.network.dns.locked"' "$menu" || fail "the menu shows a locked Family DNS row"
if grep -q '"setup.network.dns.locked".*"disabled"' "$menu"; then
  fail "the locked Family DNS row must not use disabled: (that check mark means already installed)"
fi
grep -q '"checked":"true"' "$menu" || fail "the locked Family DNS row is marked as the current choice"
sudoers=$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/etc/sudoers.d/omarchy-dns")
[[ $sudoers == *'/usr/bin/omarchy-dns Families'* && $sudoers == *'/usr/bin/omarchy-dns Security'* ]] ||
  fail "the dns sudoers rule grants Families and Security to %wheel"
pass "the menu hides the picker when locked and sudoers grants Families to wheel"

dispatcher="$ROOT/etc/NetworkManager/dispatcher.d/10-omarchy-parent-dns"
[[ -f $dispatcher ]] || fail "the NetworkManager dispatcher ships"
case_arm=$(grep -E 'up\|dhcp4-change\|dhcp6-change' "$dispatcher")
[[ $case_arm == *reapply* ]] && fail "the dispatcher must not handle reapply, which would loop on its own fix"
if grep -E '^[[:space:]]*(omarchy-parent-dns apply|systemctl|conf_set|browser_policy|dns_filter)' "$dispatcher"; then
  fail "the dispatcher must only fix the one connection, not apply/resolved/browser policy/filter"
fi
grep -Fq 'omarchy-parent-dns fix-connection' "$dispatcher" ||
  fail "the dispatcher calls fix-connection for the upped UUID"

dispatcher_bin=$test_tmp/dispatcher-bin
mkdir -p "$dispatcher_bin"
: >"$test_tmp/dispatcher.log"
cat >"$dispatcher_bin/omarchy-profile-child" <<'SH'
#!/bin/bash
exit 0
SH
cat >"$dispatcher_bin/omarchy-parent-dns" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$test_tmp/dispatcher.log"
if [[ \$1 == locked ]]; then
  exit \${LOCKED_EXIT:-0}
fi
exit 0
SH
chmod +x "$dispatcher_bin"/*

run_dispatcher() {
  local iface=$1 action=$2
  : >"$test_tmp/dispatcher.log"
  env -i PATH="$dispatcher_bin:/usr/bin:/bin" CONNECTION_UUID="${CONNECTION_UUID-}" \
    DEVICE_IFACE="${DEVICE_IFACE-}" LOCKED_EXIT="${LOCKED_EXIT-0}" \
    OMARCHY_PARENT_DNS_LOCK="$test_tmp/dispatcher.lock" \
    bash "$dispatcher" "$iface" "$action" || true
}

CONNECTION_UUID=conn-aaa DEVICE_IFACE=wlan0 run_dispatcher wlan0 up
[[ $(<"$test_tmp/dispatcher.log") == *$'\nfix-connection conn-aaa wlan0' || $(<"$test_tmp/dispatcher.log") == *'fix-connection conn-aaa wlan0' ]] ||
  fail "the dispatcher fixes only the upped connection" "$(<"$test_tmp/dispatcher.log")"
CONNECTION_UUID=conn-aaa DEVICE_IFACE=wlan0 run_dispatcher wlan0 reapply
[[ ! -s $test_tmp/dispatcher.log ]] || fail "the dispatcher ignores reapply" "$(<"$test_tmp/dispatcher.log")"
CONNECTION_UUID=conn-aaa DEVICE_IFACE=wlan0 run_dispatcher wlan0 down
[[ ! -s $test_tmp/dispatcher.log ]] || fail "the dispatcher ignores down" "$(<"$test_tmp/dispatcher.log")"
unset CONNECTION_UUID
DEVICE_IFACE=wlan0 run_dispatcher wlan0 up
[[ ! -s $test_tmp/dispatcher.log ]] || fail "the dispatcher no-ops without CONNECTION_UUID" "$(<"$test_tmp/dispatcher.log")"
CONNECTION_UUID=conn-aaa DEVICE_IFACE=wlan0 LOCKED_EXIT=1 run_dispatcher wlan0 up
[[ $(<"$test_tmp/dispatcher.log") == *locked* && $(<"$test_tmp/dispatcher.log") != *fix-connection* ]] ||
  fail "the dispatcher no-ops unless family DNS is locked" "$(<"$test_tmp/dispatcher.log")"
pass "the dispatcher is narrow: one connection, up/dhcp only"

# Elevate once, drop the ticket, then apply as root. apply_mode and the
# helpers it calls must not call sudo or pkexec after that.
if grep -E '^[[:space:]]*(exec[[:space:]]+)?(sudo|pkexec)[[:space:]]' "$parent_dns" | grep -Evq 'sudo env OMARCHY_PATH=|sudo -k'; then
  fail "omarchy-parent-dns must not call sudo after the outer parent elevation"
fi
grep -Fq 'sudo env OMARCHY_PATH=' "$parent_dns" ||
  fail "omarchy-parent-dns elevates with one sudo"
grep -Fq 'status=0' "$parent_dns" ||
  fail "omarchy-parent-dns keeps the elevated status across sudo -k"
grep -Fq 'sudo -k' "$parent_dns" ||
  fail "omarchy-parent-dns drops the sudo ticket when it finishes"
grep -Fq 'sudo env OMARCHY_PATH="$OMARCHY_PATH" "$0" "$@" || status=$?' "$parent_dns" ||
  fail "omarchy-parent-dns still drops the ticket when elevation fails"
if grep -qE '^[[:space:]]*trap ' "$parent_dns"; then
  fail "omarchy-parent-dns must not set an EXIT trap"
fi
grep -Fq 'if (( EUID != 0 )); then' "$parent_dns" ||
  fail "omarchy-parent-dns elevates once, then apply_mode runs as root"
require_root_fn=$(sed -n '/^require_root() {/,/^}/p' "$dns")
[[ $require_root_fn == *'if (( EUID == 0 )); then'*return* ]] ||
  fail "omarchy-dns require_root is a no-op when the parent command already holds root"
as_root_fn=$(<"$ROOT/install/helpers/as-root.sh")
[[ $as_root_fn == *'if (( EUID == 0 )); then'*'"$@"'* ]] ||
  fail "as_root does not re-prompt when the parent command already holds root"
if grep -nE '^[[:space:]]*trap ' "$ROOT/install/helpers/parent.sh" "$ROOT/install/helpers/dns.sh" "$ROOT/install/helpers/browser-policy.sh" "$ROOT/install/helpers/parent-dns-filter.sh" | grep -v 'trap '"'"'rm -f'; then
  fail "sourced helpers must not install an EXIT trap that runs sudo -k"
fi
grep -Fq 'browser_policy_apply_doh families' "$parent_dns" ||
  fail "on pins browser DoH to the family endpoint"
grep -Fq 'browser_policy_apply_doh security' "$parent_dns" ||
  fail "security pins browser DoH to the security endpoint"
grep -Fq 'dns_filter_apply families' "$parent_dns" ||
  fail "on loads the family DNS egress filter"
grep -Fq 'dns_filter_clear' "$parent_dns" ||
  fail "off removes the family DNS egress filter"
pass "the parent-dns apply path has no nested sudo"

if (( EUID != 0 )); then
  sudo_k=$test_tmp/sudo-k
  mkdir -p "$sudo_k/bin"
  : >"$sudo_k/log"
  cat >"$sudo_k/bin/sudo" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$sudo_k/log"
if [[ \$1 == -k ]]; then
  exit 0
fi
exit 7
SH
  chmod +x "$sudo_k/bin/sudo"
  set +e
  PATH="$sudo_k/bin:/usr/bin:/bin" OMARCHY_PATH="$ROOT" bash "$parent_dns" on >/dev/null 2>&1
  sudo_k_status=$?
  set -e
  (( sudo_k_status == 7 )) || fail "a failed elevated parent-dns run keeps the sudo exit status" "status=$sudo_k_status"
  grep -Fxq -- '-k' "$sudo_k/log" || fail "a failed elevated parent-dns run still calls sudo -k" "$(<"$sudo_k/log")"
  pass "a failed elevated run still calls sudo -k"
else
  pass "running as root; skipping the unprivileged sudo -k probe"
fi

# Caller EXIT trap still runs around the unprivileged wrapper. sudo -k
# happens after the elevated work, not from a sourced helper trap.
dns_sudo_bin=$test_tmp/dns-sudo-bin
mkdir -p "$dns_sudo_bin"
dns_sudo_log=$test_tmp/dns-sudo.log
dns_caller_partial=$test_tmp/dns-caller-partial
cat >"$dns_sudo_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_SUDO_LOG"
if [[ $1 == -k ]]; then
  exit 0
fi
exit "${OMARCHY_TEST_SUDO_STATUS:-0}"
SH
chmod +x "$dns_sudo_bin/sudo"

: >"$dns_sudo_log"
: >"$dns_caller_partial"
OMARCHY_TEST_SUDO_STATUS=0 OMARCHY_TEST_SUDO_LOG="$dns_sudo_log" \
  PATH="$dns_sudo_bin:$PATH" \
  bash -c '
    trap '"'"'rm -f "$1" # dns-caller-partial'"'"' EXIT
    bash "$2" on
    trap -p EXIT | grep -Fq dns-caller-partial || exit 2
  ' _ "$dns_caller_partial" "$parent_dns"
[[ ! -f $dns_caller_partial ]] || fail "parent-dns left the caller EXIT trap in place"
grep -Fq "env OMARCHY_PATH=" "$dns_sudo_log" ||
  fail "parent-dns elevates with sudo env" "$(cat "$dns_sudo_log")"
grep -qxF -- '-k' "$dns_sudo_log" ||
  fail "parent-dns drops the ticket on success" "$(cat "$dns_sudo_log")"
(( $(grep -c -e . "$dns_sudo_log") == 2 )) ||
  fail "parent-dns asks sudo only to elevate and to drop the ticket" "$(cat "$dns_sudo_log")"
pass "parent-dns drops the ticket on success and keeps the caller EXIT trap"

: >"$dns_sudo_log"
: >"$dns_caller_partial"
if OMARCHY_TEST_SUDO_STATUS=1 OMARCHY_TEST_SUDO_LOG="$dns_sudo_log" \
  PATH="$dns_sudo_bin:$PATH" \
  bash -c '
    trap '"'"'rm -f "$1"'"'"' EXIT
    bash "$2" on
  ' _ "$dns_caller_partial" "$parent_dns"; then
  fail "parent-dns reports a failed elevation"
fi
[[ ! -f $dns_caller_partial ]] || fail "parent-dns still runs the caller EXIT trap after a failed elevation"
grep -qxF -- '-k' "$dns_sudo_log" ||
  fail "parent-dns drops the ticket after a failed elevation" "$(cat "$dns_sudo_log")"
pass "parent-dns drops the ticket on a failed elevation and keeps the caller EXIT trap"

# Already-root run: a sudo/pkexec that records and fails would be a second
# parent-password prompt. unshare maps this process to root so the outer
# elevation is skipped, matching `sudo omarchy-parent dns`.
sudo_probe=$test_tmp/sudo-probe
mkdir -p "$sudo_probe/bin" "$sudo_probe/localbin"
: >"$sudo_probe/log"
printf '#!/bin/bash\nprintf "sudo %s\\n" "$*" >>%q\nexit 1\n' "$sudo_probe/log" >"$sudo_probe/bin/sudo"
printf '#!/bin/bash\nprintf "pkexec %s\\n" "$*" >>%q\nexit 1\n' "$sudo_probe/log" >"$sudo_probe/bin/pkexec"
printf '#!/bin/bash\nprintf "nft %%s\\n" "$*" >>%q\nexit 0\n' "$sudo_probe/nft.log" >"$sudo_probe/bin/nft"
printf '#!/bin/bash\nprintf "systemctl %%s\\n" "$*" >>%q\nif [[ $1 == is-active ]]; then\n  exit 1\nfi\nexit 0\n' "$sudo_probe/systemctl.log" >"$sudo_probe/bin/systemctl"
cp "$ROOT/bin/omarchy-profile-child" "$sudo_probe/localbin/omarchy-profile-child"
cat >"$sudo_probe/localbin/systemctl" <<'SH'
#!/bin/bash
if [[ $1 == is-active ]]; then
  exit 1
fi
exit 0
SH
cat >"$sudo_probe/localbin/nmcli" <<SH
#!/bin/bash
printf 'nmcli %s\n' "\$*" >>"$sudo_probe/nmcli.log"
exit 1
SH
chmod +x "$sudo_probe/bin"/* "$sudo_probe/localbin"/*
printf 'child\n' >"$sudo_probe/profile"

run_parent_dns_as_root() {
  local mode=$1
  unshare --user --map-root-user --mount env \
    OMARCHY_PATH="$ROOT" \
    OMARCHY_PROFILE_FILE="$sudo_probe/profile" \
    OMARCHY_PARENT_CONF="$sudo_probe/parent.conf" \
    OMARCHY_NM_DNS_CONF="$sudo_probe/20-omarchy-dns.conf" \
    OMARCHY_RESOLVED_CONF="$sudo_probe/resolved.conf" \
    OMARCHY_PARENT_DNS_NFT_FILE="$sudo_probe/parent-dns-filter.nft" \
    OMARCHY_PARENT_DNS_FILTER_UNIT="$sudo_probe/omarchy-parent-dns-filter.service" \
    PATH="$sudo_probe/bin:$ROOT/bin:/usr/bin:/bin" \
    bash -c '
      set -euo pipefail
      if [[ -d /usr/local/bin ]]; then
        mount --bind "'"$sudo_probe"'/localbin" /usr/local/bin
      fi
      if [[ -e /usr/bin/sudo ]]; then
        mount --bind "'"$sudo_probe"'/bin/sudo" /usr/bin/sudo
      fi
      if [[ -e /usr/bin/pkexec ]]; then
        mount --bind "'"$sudo_probe"'/bin/pkexec" /usr/bin/pkexec
      fi
      exec bash "'"$ROOT"'/bin/omarchy-parent-dns" "'"$mode"'"
    '
}

if (( EUID == 0 )) || unshare --user --map-root-user --mount true 2>/dev/null; then
  for mode in on security off; do
    : >"$sudo_probe/log"
    : >"$sudo_probe/nmcli.log"
    run_parent_dns_as_root "$mode" >/dev/null ||
      fail "omarchy-parent-dns $mode succeeds once already root"
    if [[ -s $sudo_probe/log ]]; then
      fail "omarchy-parent-dns $mode must not call sudo again after the parent elevation" "$(<"$sudo_probe/log")"
    fi
    if [[ -s $sudo_probe/nmcli.log ]]; then
      fail "omarchy-parent-dns $mode must not call nmcli when NetworkManager is inactive" "$(<"$sudo_probe/nmcli.log")"
    fi
  done
  pass "omarchy-parent dns on|off|security asks for the parent password only once"
else
  pass "no unprivileged user namespace; skipping the already-root parent-dns probe"
fi

# fix-connection: matching profile is a no-op; a mismatch touches only that
# uuid and device.
fix_bin=$test_tmp/fix-bin
mkdir -p "$fix_bin"
: >"$test_tmp/nmcli.log"
cat >"$fix_bin/omarchy-profile-child" <<'SH'
#!/bin/bash
[[ $(<"${OMARCHY_PROFILE_FILE:-/etc/omarchy/profile}") == child ]]
SH
cat >"$fix_bin/nmcli" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$test_tmp/nmcli.log"
if [[ \$1 == -t && \$2 == -f && \$4 == connection && \$5 == show ]]; then
  if [[ \${NMCLI_MATCH:-0} == 1 ]]; then
    cat <<'EOF'
ipv4.ignore-auto-dns:yes
ipv4.dns:1.1.1.3,1.0.0.3
ipv6.ignore-auto-dns:yes
ipv6.dns:2606:4700:4700::1113,2606:4700:4700::1003
EOF
  else
    cat <<'EOF'
ipv4.ignore-auto-dns:no
ipv4.dns:
ipv6.ignore-auto-dns:no
ipv6.dns:
EOF
  fi
  exit 0
fi
exit 0
SH
chmod +x "$fix_bin"/*

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
printf 'dns=on\n' >"$OMARCHY_PARENT_CONF"

invoke_fix() {
  local match=$1 uuid=$2 device=$3
  : >"$test_tmp/nmcli.log"
  if (( EUID == 0 )); then
    NMCLI_MATCH="$match" PATH="$fix_bin:$ROOT/bin:/usr/bin:/bin" \
      OMARCHY_PATH="$ROOT" \
      OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
      OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" \
      bash "$parent_dns" fix-connection "$uuid" "$device"
  else
    unshare --user --map-root-user env \
      NMCLI_MATCH="$match" \
      PATH="$fix_bin:$ROOT/bin:/usr/bin:/bin" \
      OMARCHY_PATH="$ROOT" \
      OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
      OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" \
      bash "$parent_dns" fix-connection "$uuid" "$device"
  fi
}

if (( EUID == 0 )) || unshare --user --map-root-user true 2>/dev/null; then
  invoke_fix 1 uuid-match wlan0
  if grep -q 'connection modify\|device reapply' "$test_tmp/nmcli.log"; then
    fail "fix-connection is a no-op when the connection already matches" "$(<"$test_tmp/nmcli.log")"
  fi
  invoke_fix 0 uuid-miss eth0
  grep -q 'connection modify uuid-miss' "$test_tmp/nmcli.log" ||
    fail "fix-connection modifies only the mismatched uuid" "$(<"$test_tmp/nmcli.log")"
  grep -q 'device reapply eth0' "$test_tmp/nmcli.log" ||
    fail "fix-connection reapplies only the given device" "$(<"$test_tmp/nmcli.log")"
  pass "fix-connection is idempotent and scoped to one connection"
else
  pass "no unprivileged user namespace; skipping the fix-connection nmcli probe"
fi

# Write Families into scratch files without talking to NetworkManager.
if (( EUID == 0 )); then
  pass "running as root; skipping the scratch writer, which would still be safe but is covered unprivileged"
  exit 0
fi

printf 'default\n' >"$OMARCHY_PROFILE_FILE"
rm -f "$OMARCHY_PARENT_CONF"
bash -euo pipefail -c '
  source "$1"
  NM_DNS_CONF="$2"
  RESOLVED_CONF="$3"
  write_networkmanager_dns() {
    local servers="$1"
    install -d -m 0755 "$(dirname "$NM_DNS_CONF")"
    cat >"$NM_DNS_CONF" <<EOF
[global-dns]
[global-dns-domain-*]
servers=$servers
EOF
  }
  write_resolved_conf() {
    local dns_line="${1:-}"
    local dot="${2:-}"
    local fallback="${3:-}"
    {
      echo "[Resolve]"
      [[ -n $dns_line ]] && echo "DNS=$dns_line"
      [[ -n $fallback ]] && echo "FallbackDNS=$fallback"
      [[ -n $dot ]] && echo "DNSOverTLS=$dot"
    } >"$RESOLVED_CONF"
  }
  write_networkmanager_dns "$(dns_provider_nm_servers Families)"
  fallback=$(dns_provider_fallback Families)
  write_resolved_conf "$(dns_provider_resolved Families)" "$(dns_provider_dot Families)" "$fallback"
' _ "$helper" "$NM_DNS_CONF" "$RESOLVED_CONF"

grep -Fq 'servers=1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003' "$NM_DNS_CONF" ||
  fail "Families writes the malware+adult addresses into NetworkManager"
grep -Fq '1.1.1.3#family.cloudflare-dns.com' "$RESOLVED_CONF" ||
  fail "Families writes the family DoT name into resolved"
grep -Fq 'DNSOverTLS=yes' "$RESOLVED_CONF" || fail "Families enables strict DNS-over-TLS"
grep -Fq 'FallbackDNS=1.1.1.3#family.cloudflare-dns.com' "$RESOLVED_CONF" ||
  fail "Families must pin FallbackDNS to the filtered resolver"
grep -Fq '1.0.0.3#family.cloudflare-dns.com' "$RESOLVED_CONF" ||
  fail "Families must pin the second family IPv4 in DNS and FallbackDNS"
grep -Fq '2606:4700:4700::1113#family.cloudflare-dns.com' "$RESOLVED_CONF" ||
  fail "Families must pin family IPv6 in DNS and FallbackDNS"
if grep -Fq '9.9.9.9#dns.quad9.net' "$RESOLVED_CONF"; then
  fail "Families must not write the unfiltered Quad9 fallback"
fi
[[ $(dns_detect_provider) == "Families" ]] || fail "the files just written detect as Families"
pass "Families writes strict DoT with a filtered FallbackDNS"

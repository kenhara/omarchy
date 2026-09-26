#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

dns="$ROOT/bin/omarchy-dns"
parent_dns="$ROOT/bin/omarchy-parent-dns"
helper="$ROOT/install/helpers/dns.sh"
leaf="$ROOT/install/config/dns.sh"
dispatcher="$ROOT/etc/NetworkManager/dispatcher.d/99-omarchy-parent-dns"
sudoers_file="$ROOT/etc/sudoers.d/omarchy-dns"

[[ -x $parent_dns ]] || fail "omarchy-parent-dns is executable"
grep -q '^# omarchy:summary=Family DNS filtering' "$parent_dns" ||
  fail "omarchy-parent-dns carries command metadata"
grep -q '^# omarchy:requires-sudo=true' "$parent_dns" ||
  fail "omarchy-parent-dns is marked as requiring sudo"
grep -Fq 'source "$OMARCHY_PATH/install/helpers/parent.sh"' "$parent_dns" ||
  fail "omarchy-parent-dns sources the shared parent helper"
grep -Fq 'source "$OMARCHY_PATH/install/helpers/dns.sh"' "$parent_dns" ||
  fail "omarchy-parent-dns sources the shared DNS helper"
grep -Fq 'omarchy-parent-dns on' "$leaf" || fail "the install leaf turns Family DNS on"
grep -Fq '== "child"' "$leaf" || fail "the install leaf only runs on child installs"
grep -Fq 'run_logged "$OMARCHY_INSTALL/config/dns.sh"' "$ROOT/install/config/all.sh" ||
  fail "the DNS install leaf is wired into system setup"
grep -Fq 'omarchy-parent-dns on' "$ROOT/bin/omarchy-provision-owner" ||
  fail "deferred child provisioning turns Family DNS on"
pass "omarchy-parent-dns is wired as a parent feature and an install leaf"

if grep -E 'Families|Security|1\.1\.1\.[23]' "$sudoers_file" >/dev/null; then
  fail "dns sudoers must not grant Families or Security passwordless"
fi
pass "Families and Security stay off the passwordless DNS sudoers grant"

[[ -f $dispatcher ]] || fail "the NetworkManager dispatcher ships"
grep -Fq 'apply --if-needed --connection' "$dispatcher" ||
  fail "the dispatcher only re-applies a locked connection"
grep -Fq '[[ ${2:-} == "up" ]]' "$dispatcher" ||
  fail "the dispatcher runs on connection up, not every DHCP refresh"
pass "the NetworkManager dispatcher re-applies the lock on new connections"

run_node_test <<'JS'
const network = requireFromRoot('shell/plugins/panels/network/Model.js')
assertDeepEqual(network.dnsProviderList(),
  ['DHCP', 'Cloudflare', 'Google', 'Families', 'Security', 'Custom'],
  'the network panel lists Families and Security with the stock providers')
assertEqual(network.dnsLocked(false, 'families'), false, 'an adult install is never DNS-locked')
assertEqual(network.dnsLocked(true, 'off'), false, 'a child install is unlocked when dns=off')
assertEqual(network.dnsLocked(true, 'families'), true, 'a child install locks on families')
assertEqual(network.dnsLocked(true, 'security'), true, 'a child install locks on security')
assertEqual(network.dnsLockTitle('security'), 'Security DNS · locked', 'security lock title')
assertEqual(network.dnsLockTitle('families'), 'Family DNS · locked', 'families lock title')
assertEqual(network.dnsTooltip('Families'), 'Cloudflare Families (malware + adult)', 'Families tooltip')
assertEqual(network.dnsTooltip('Security'), 'Cloudflare Families (malware only)', 'Security tooltip')
JS
pass "network panel lock helpers classify Family DNS"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export OMARCHY_PATH="$ROOT"
export OMARCHY_NM_DNS_CONF="$test_tmp/20-omarchy-dns.conf"
export OMARCHY_RESOLVED_CONF="$test_tmp/resolved.conf"
export OMARCHY_PARENT_CONF="$test_tmp/parent.conf"
export OMARCHY_PROFILE_FILE="$test_tmp/profile"
source "$helper"

write_resolved() {
  printf '%s\n' "$1" >"$OMARCHY_RESOLVED_CONF"
}

write_nm() {
  cat >"$OMARCHY_NM_DNS_CONF" <<EOF
[global-dns]

[global-dns-domain-*]
servers=$1
EOF
}

write_nm "1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003"
[[ $(current_dns_provider) == "Families" ]] ||
  fail "1.1.1.3 in NetworkManager global-dns is Families" "got: $(current_dns_provider)"

write_resolved "DNS=1.1.1.3#family.cloudflare-dns.com 1.0.0.3#family.cloudflare-dns.com"
rm -f "$OMARCHY_NM_DNS_CONF"
[[ $(current_dns_provider) == "Families" ]] ||
  fail "family.cloudflare-dns.com in resolved.conf is Families, not Cloudflare" "got: $(current_dns_provider)"

write_resolved "DNS=1.1.1.2#security.cloudflare-dns.com"
[[ $(current_dns_provider) == "Security" ]] ||
  fail "security.cloudflare-dns.com is Security" "got: $(current_dns_provider)"

write_resolved "DNS=1.1.1.1#cloudflare-dns.com"
[[ $(current_dns_provider) == "Cloudflare" ]] ||
  fail "cloudflare-dns.com without a Families hostname is Cloudflare" "got: $(current_dns_provider)"

rm -f "$OMARCHY_RESOLVED_CONF"
[[ $(current_dns_provider) == "DHCP" ]] || fail "empty DNS config is DHCP"
pass "detection matches Families and Security before Cloudflare"

[[ $(dns_provider_from_arg families) == "Families" ]] || fail "families argument canonicalizes"
[[ $(dns_provider_from_arg security) == "Security" ]] || fail "security argument canonicalizes"
if dns_provider_from_arg Quad9; then
  fail "unknown providers are refused"
fi
pass "omarchy-dns accepts Families and Security"

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
printf 'dns=families\n' >"$OMARCHY_PARENT_CONF"
[[ $(dns_locked_provider) == "Families" ]] || fail "child + dns=families locks to Families"
if dns_refuse_if_locked DHCP; then
  fail "a locked child refuses DHCP"
fi
if dns_refuse_if_locked Cloudflare; then
  fail "a locked child refuses Cloudflare"
fi
if dns_refuse_if_locked Security; then
  fail "a Families lock refuses Security"
fi
dns_refuse_if_locked Families || fail "re-applying Families is allowed while locked"

printf 'dns=security\n' >"$OMARCHY_PARENT_CONF"
[[ $(dns_locked_provider) == "Security" ]] || fail "child + dns=security locks to Security"
dns_refuse_if_locked Security || fail "re-applying Security is allowed while locked"
if dns_refuse_if_locked Families; then
  fail "a Security lock refuses Families"
fi

printf 'dns=off\n' >"$OMARCHY_PARENT_CONF"
[[ -z $(dns_locked_provider) ]] || fail "dns=off unlocks"
dns_refuse_if_locked DHCP || fail "DHCP is allowed when unlocked"

printf 'default\n' >"$OMARCHY_PROFILE_FILE"
printf 'dns=families\n' >"$OMARCHY_PARENT_CONF"
[[ -z $(dns_locked_provider) ]] || fail "an adult install ignores the parent DNS key"
pass "the child lock refuses omarchy-dns except the held provider"

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
[[ -z $(dns_fallback) ]] || fail "a child profile omits the Quad9 fallback"
printf 'default\n' >"$OMARCHY_PROFILE_FILE"
[[ $(dns_fallback) == *quad9.net* ]] || fail "an adult Cloudflare/Google write still has Quad9"
pass "child profiles do not fall back to unfiltered Quad9"

# Exercise the writers against stubs so a test run never rewrites host DNS.
stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/nmcli" <<'SH'
#!/bin/bash
printf 'nmcli %s\n' "$*" >>"${NMCLI_LOG:-/dev/null}"
case "$1 $2" in
  "general status") exit 0 ;;
  "-t -f")
    if [[ $3 == "UUID,TYPE" ]]; then
      printf 'wifi-uuid:802-11-wireless\n'
    fi
    ;;
esac
exit 0
SH
chmod +x "$stub_bin/nmcli"
printf '#!/bin/bash\nexit 0\n' >"$stub_bin/systemctl"
chmod +x "$stub_bin/systemctl"

PATH="$stub_bin:$PATH"
export NMCLI_LOG="$test_tmp/nmcli.log"
: >"$NMCLI_LOG"

dns_apply_provider Families
grep -F '1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003' "$OMARCHY_NM_DNS_CONF" >/dev/null ||
  fail "Families writes the malware+adult anycast into NetworkManager"
grep -F '1.1.1.3#family.cloudflare-dns.com' "$OMARCHY_RESOLVED_CONF" >/dev/null ||
  fail "Families pins DoT to family.cloudflare-dns.com"
grep -Fx 'DNSOverTLS=yes' "$OMARCHY_RESOLVED_CONF" >/dev/null ||
  fail "Families uses strict DNS-over-TLS"
if grep -F 'quad9' "$OMARCHY_RESOLVED_CONF" >/dev/null; then
  fail "Families must not fall back to Quad9"
fi
grep -F 'ipv4.ignore-auto-dns yes' "$NMCLI_LOG" >/dev/null ||
  fail "Families sets per-connection ignore-auto-dns"

: >"$NMCLI_LOG"
dns_apply_provider Security
grep -F '1.1.1.2#security.cloudflare-dns.com' "$OMARCHY_RESOLVED_CONF" >/dev/null ||
  fail "Security pins DoT to security.cloudflare-dns.com"
grep -Fx 'DNSOverTLS=yes' "$OMARCHY_RESOLVED_CONF" >/dev/null ||
  fail "Security uses strict DNS-over-TLS"
if grep -F 'quad9' "$OMARCHY_RESOLVED_CONF" >/dev/null; then
  fail "Security must not fall back to Quad9"
fi
pass "Families and Security write strict DoT and no Quad9 fallback"

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
dns_apply_provider Cloudflare
if grep -F 'quad9' "$OMARCHY_RESOLVED_CONF" >/dev/null; then
  fail "a child Cloudflare write must not keep Quad9"
fi
pass "child writes never add the unfiltered Quad9 fallback"

# omarchy-dns refuses a locked change before it asks for a password.
printf 'child\n' >"$OMARCHY_PROFILE_FILE"
printf 'dns=families\n' >"$OMARCHY_PARENT_CONF"
if PATH="$stub_bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
  OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" bash "$dns" DHCP </dev/null >/dev/null 2>"$test_tmp/refuse.err"; then
  fail "omarchy-dns DHCP exits non-zero while Family DNS is locked"
fi
grep -q 'Family DNS is locked' "$test_tmp/refuse.err" ||
  fail "omarchy-dns tells the caller to use omarchy-parent dns" "$(<"$test_tmp/refuse.err")"
pass "omarchy-dns refuses locked providers before elevation"

# Status is readable without root and prints one word when stdout is not a tty.
printf 'child\n' >"$OMARCHY_PROFILE_FILE"
printf 'dns=families\n' >"$OMARCHY_PARENT_CONF"
mode=$(PATH="$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
  OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" bash "$parent_dns" </dev/null)
[[ $mode == "families" ]] || fail "omarchy-parent-dns prints the lock word" "got: $mode"

printf 'default\n' >"$OMARCHY_PROFILE_FILE"
mode=$(PATH="$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
  OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" bash "$parent_dns" </dev/null)
[[ $mode == "off" ]] || fail "omarchy-parent-dns is off on a default install" "got: $mode"
pass "omarchy-parent-dns status is one word without a password"

# Browser policy: Chromium drop-in and a Firefox merge that keeps VAAPI.
source "$ROOT/install/helpers/browser-policy.sh"
unprivileged_as_root() {
  if [[ $1 == "install" ]]; then
    shift
    local args=() skip=0 arg
    for arg in "$@"; do
      if (( skip )); then skip=0; continue; fi
      case $arg in
        -o|-g) skip=1 ;;
        *) args+=("$arg") ;;
      esac
    done
    command install "${args[@]}"
  else
    "$@"
  fi
}
as_root() { unprivileged_as_root "$@"; }

chromium_dir="$test_tmp/chromium/managed"
mkdir -p "$chromium_dir"
browser_policy_install_dns "$chromium_dir" lock || fail "dns.json writes into a managed directory"
grep -F '"DnsOverHttpsMode": "off"' "$chromium_dir/dns.json" >/dev/null ||
  fail "dns.json turns Chromium DoH off"
mode=$(stat -c '%a' "$chromium_dir/dns.json")
[[ $mode == "644" ]] || fail "dns.json is 0644" "mode=$mode"
browser_policy_install_dns "$chromium_dir" unlock || fail "unlock removes dns.json"
[[ ! -e $chromium_dir/dns.json ]] || fail "unlock deletes dns.json"

fx_dir="$test_tmp/firefox/distribution"
mkdir -p "$fx_dir"
install -m 0644 -T "$ROOT/default/firefox/policies.json" "$fx_dir/policies.json"
browser_policy_install_firefox_dns "$fx_dir" lock || fail "Firefox DNS merge succeeds"
python3 - "$fx_dir/policies.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
prefs = data["policies"]["Preferences"]
assert prefs["media.ffmpeg.vaapi.enabled"]["Value"] is True
doh = data["policies"]["DNSOverHTTPS"]
assert doh["Enabled"] is False and doh["Locked"] is True
PY
browser_policy_install_firefox_dns "$fx_dir" unlock || fail "Firefox DNS unlock succeeds"
python3 - "$fx_dir/policies.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "DNSOverHTTPS" not in data["policies"]
assert data["policies"]["Preferences"]["media.ffmpeg.vaapi.enabled"]["Value"] is True
PY
pass "browser policy turns DoH off and keeps Firefox VAAPI keys"

menu="$ROOT/default/omarchy/omarchy-menu.jsonc"
grep -q '"setup.network.dns.families"' "$menu" || fail "the menu offers Families"
grep -q '"setup.network.dns.security"' "$menu" || fail "the menu offers Security"
grep -q '"setup.network.dns.locked"' "$menu" || fail "the menu shows a locked Family DNS row"
grep -F '$(omarchy-parent-dns)' "$menu" >/dev/null || fail "DNS menu rows read the parent lock"
pass "the menu gates DNS changes on the Family DNS lock"

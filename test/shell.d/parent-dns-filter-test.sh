#!/bin/bash
#
# Family DNS egress filter: the nftables table contents, mode-specific DoH
# sets, apply/clear against stubs, chroot must not load live rules, and the
# child-install migration.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

helper="$ROOT/install/helpers/parent-dns-filter.sh"
parent_dns="$ROOT/bin/omarchy-parent-dns"
migration=$(grep -l 'family DNS egress filter' "$ROOT"/migrations/*.sh | tail -1)

[[ -n $migration && -f $migration ]] || fail "a family DNS egress-filter migration ships"
[[ $(stat -c '%a' "$migration") == 644 ]] || fail "the egress-filter migration is 0644"
! grep -q '^#!' "$migration" || fail "the egress-filter migration has no shebang"
grep -Fq 'nftables' "$ROOT/install/omarchy-child.packages" ||
  fail "child installs include nftables for the egress filter"
grep -Fq 'source "$OMARCHY_PATH/install/helpers/parent-dns-filter.sh"' "$parent_dns" ||
  fail "omarchy-parent-dns sources the egress-filter helper"
pass "the egress filter is wired into parent-dns, child packages, and a migration"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

export OMARCHY_PATH="$ROOT"
export OMARCHY_PROFILE_FILE="$test_tmp/profile"
export OMARCHY_PARENT_CONF="$test_tmp/parent.conf"
export OMARCHY_PARENT_DNS_NFT_FILE="$test_tmp/parent-dns-filter.nft"
export OMARCHY_PARENT_DNS_FILTER_UNIT="$test_tmp/omarchy-parent-dns-filter.service"

source "$ROOT/install/helpers/dns.sh"
source "$helper"

rendered=$(dns_filter_render families)
[[ $rendered == *"destroy table inet omarchy-parent-dns"* ]] ||
  fail "render starts by destroying the previous table"
[[ $rendered == *"meta skuid >= 1000 udp dport 53 drop"* ]] ||
  fail "render drops kid-uid outbound DNS"
[[ $rendered == *"meta skuid >= 1000 tcp dport 853 drop"* ]] ||
  fail "render drops kid-uid DoT"
[[ $rendered == *"ip daddr 127.0.0.0/8 accept"* && $rendered == *"ip6 daddr ::1 accept"* ]] ||
  fail "render allows the resolved stub on loopback"
[[ $rendered == *"8.8.8.8"* && $rendered == *"8.8.4.4"* ]] ||
  fail "render blocks Google DoH"
[[ $rendered == *"1.1.1.1"* && $rendered == *"1.0.0.1"* ]] ||
  fail "render blocks unfiltered Cloudflare DoH"
[[ $rendered == *"9.9.9.9"* && $rendered == *"149.112.112.112"* ]] ||
  fail "render blocks Quad9 DoH"
[[ $rendered == *"208.67.222.222"* ]] || fail "render blocks OpenDNS DoH"
[[ $rendered == *"2001:4860:4860::8888"* && $rendered == *"2606:4700:4700::1111"* ]] ||
  fail "render blocks Google and Cloudflare IPv6 DoH"
if [[ $rendered == *"1.1.1.3"* || $rendered == *"1.0.0.3"* || $rendered == *"::1113"* || $rendered == *"::1003"* ]]; then
  fail "Families filter must not block the family resolvers themselves"
fi
[[ $rendered == *"1.1.1.2"* && $rendered == *"1.0.0.2"* ]] ||
  fail "Families mode also blocks the malware-only Cloudflare DoH endpoints"
pass "Families nftables render drops outside DNS/DoT/DoH and keeps family resolvers"

security_rendered=$(dns_filter_render security)
if [[ $security_rendered == *"1.1.1.2"* || $security_rendered == *"1.0.0.2"* || $security_rendered == *"::1112"* ]]; then
  fail "Security filter must not block the security resolvers"
fi
[[ $security_rendered == *"1.1.1.1"* && $security_rendered == *"8.8.8.8"* ]] ||
  fail "Security filter still blocks unfiltered public DoH"
pass "Security nftables render keeps the security resolvers"

unit=$(dns_filter_render_unit)
[[ $unit == *"$PARENT_DNS_NFT_FILE"* ]] || fail "the oneshot unit loads the written nft file"
[[ $unit == *"destroy table inet $PARENT_DNS_NFT_TABLE"* ]] ||
  fail "the oneshot unit destroys the table on stop"
[[ $unit == *"After=ufw.service"* ]] || fail "the oneshot unit starts after UFW"
pass "the filter unit is a oneshot that loads and unloads the table"

stub_bin=$test_tmp/bin
mkdir -p "$stub_bin"
: >"$test_tmp/filter.log"
cat >"$stub_bin/nft" <<SH
#!/bin/bash
printf 'nft %s\n' "\$*" >>"$test_tmp/filter.log"
exit 0
SH
cat >"$stub_bin/systemctl" <<SH
#!/bin/bash
printf 'systemctl %s\n' "\$*" >>"$test_tmp/filter.log"
exit 0
SH
cat >"$stub_bin/systemd-detect-virt" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub_bin"/*

(
  PATH="$stub_bin:/usr/bin:/bin"
  mkdir -p "$test_tmp/run-systemd/system"
  dns_filter_live() { [[ -d $test_tmp/run-systemd/system ]]; }
  : >"$test_tmp/filter.log"
  dns_filter_apply families
  grep -Fq "nft -f $PARENT_DNS_NFT_FILE" "$test_tmp/filter.log" ||
    fail "live apply loads the nft file" "$(<"$test_tmp/filter.log")"
  grep -Fq 'systemctl enable --now omarchy-parent-dns-filter.service' "$test_tmp/filter.log" ||
    fail "live apply enables and starts the oneshot" "$(<"$test_tmp/filter.log")"
  [[ -f $PARENT_DNS_NFT_FILE && -f $PARENT_DNS_FILTER_UNIT ]] ||
    fail "live apply writes the nft file and unit"
  grep -Fq '8.8.8.8' "$PARENT_DNS_NFT_FILE" || fail "the written nft file contains the DoH set"
  : >"$test_tmp/filter.log"
  dns_filter_clear
  grep -Fq 'systemctl disable --now omarchy-parent-dns-filter.service' "$test_tmp/filter.log" ||
    fail "live clear stops the oneshot" "$(<"$test_tmp/filter.log")"
  grep -Fq "nft destroy table inet $PARENT_DNS_NFT_TABLE" "$test_tmp/filter.log" ||
    fail "live clear destroys the table" "$(<"$test_tmp/filter.log")"
  [[ ! -e $PARENT_DNS_NFT_FILE && ! -e $PARENT_DNS_FILTER_UNIT ]] ||
    fail "live clear removes the nft file and unit"
)
pass "apply writes and loads the filter; clear removes it"

(
  PATH="$stub_bin:/usr/bin:/bin"
  dns_filter_live() { return 1; }
  : >"$test_tmp/filter.log"
  dns_filter_apply families
  if grep -q '^nft ' "$test_tmp/filter.log"; then
    fail "chroot apply must not load nft on the installer kernel" "$(<"$test_tmp/filter.log")"
  fi
  grep -Fq 'systemctl enable omarchy-parent-dns-filter.service' "$test_tmp/filter.log" ||
    fail "chroot apply enables the unit for first boot" "$(<"$test_tmp/filter.log")"
  if grep -q 'enable --now' "$test_tmp/filter.log"; then
    fail "chroot apply must not start the filter in the live session" "$(<"$test_tmp/filter.log")"
  fi
  : >"$test_tmp/filter.log"
  dns_filter_clear
  grep -Fq 'systemctl disable omarchy-parent-dns-filter.service' "$test_tmp/filter.log" ||
    fail "chroot clear disables the unit" "$(<"$test_tmp/filter.log")"
  if grep -q '^nft ' "$test_tmp/filter.log"; then
    fail "chroot clear must not destroy a table on the installer kernel" "$(<"$test_tmp/filter.log")"
  fi
)
pass "the ISO chroot only enables the unit; it does not touch the live firewall"

# Migration: adult and unlocked child are no-ops; locked child calls apply
# through $OMARCHY_PATH/bin/omarchy-parent-dns.
fake=$test_tmp/fake-omarchy
mkdir -p "$fake/bin" "$fake/install/helpers"
cp "$ROOT/install/helpers/dns.sh" "$ROOT/install/helpers/parent.sh" "$fake/install/helpers/"
: >"$test_tmp/mig.log"
cat >"$fake/bin/omarchy-parent-dns" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$test_tmp/mig.log"
exit 0
SH
chmod +x "$fake/bin/omarchy-parent-dns"

run_migration() {
  OMARCHY_PATH="$fake" OMARCHY_PROFILE_FILE="$OMARCHY_PROFILE_FILE" \
    OMARCHY_PARENT_CONF="$OMARCHY_PARENT_CONF" \
    bash -euo pipefail "$migration"
}

printf 'default\n' >"$OMARCHY_PROFILE_FILE"
rm -f "$OMARCHY_PARENT_CONF"
: >"$test_tmp/mig.log"
run_migration
[[ ! -s $test_tmp/mig.log ]] || fail "the migration no-ops on an adult install" "$(<"$test_tmp/mig.log")"

printf 'child\n' >"$OMARCHY_PROFILE_FILE"
printf 'dns=off\n' >"$OMARCHY_PARENT_CONF"
: >"$test_tmp/mig.log"
run_migration
[[ ! -s $test_tmp/mig.log ]] || fail "the migration no-ops when family DNS is off" "$(<"$test_tmp/mig.log")"

printf 'dns=on\n' >"$OMARCHY_PARENT_CONF"
: >"$test_tmp/mig.log"
run_migration
[[ $(<"$test_tmp/mig.log") == apply ]] ||
  fail "the migration reapplies a locked child install" "$(<"$test_tmp/mig.log")"
run_migration
(( $(grep -c -e . "$test_tmp/mig.log") == 2 )) ||
  fail "the migration is safe to run twice" "$(<"$test_tmp/mig.log")"
pass "the migration reapplies only a locked child install"

#!/bin/bash
#
# The install profile is the one fact kids mode keys on in both repos: a
# one-word marker written once by omarchy-apply-system --profile and read at
# runtime by omarchy-profile-child.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

predicate="$ROOT/bin/omarchy-profile-child"
apply_system="$ROOT/bin/omarchy-apply-system"
marker="$tmp_dir/profile"

# The predicate

if OMARCHY_PROFILE_FILE="$marker" bash "$predicate"; then
  fail "a machine with no profile marker is not a child install"
fi
printf 'default\n' >"$marker"
if OMARCHY_PROFILE_FILE="$marker" bash "$predicate"; then
  fail "the default profile is not a child install"
fi
pass "omarchy-profile-child is false without a marker and on the default profile"

printf 'child\n' >"$marker"
OMARCHY_PROFILE_FILE="$marker" bash "$predicate" || fail "the child marker makes omarchy-profile-child true"
printf 'child' >"$marker"
OMARCHY_PROFILE_FILE="$marker" bash "$predicate" || fail "omarchy-profile-child tolerates a marker without a trailing newline"
printf 'childish\n' >"$marker"
if OMARCHY_PROFILE_FILE="$marker" bash "$predicate"; then
  fail "omarchy-profile-child matches the whole word, not a prefix"
fi
pass "omarchy-profile-child is true only for the child profile"

grep -q '^# omarchy:summary=' "$predicate" || fail "omarchy-profile-child carries command metadata"
grep -Fq 'GROUP_DESCRIPTIONS[profile]=' "$ROOT/bin/omarchy" || fail "the profile group is described for the CLI listing"
pass "the profile predicate is a documented CLI command"

# omarchy-apply-system records the profile. It refuses to run unprivileged, so
# its side of the contract is asserted from the source: the flag, the allowed
# values, the marker path the predicate reads, and the variable the leaves see.

grep -Fq -- '--profile)' "$apply_system" || fail "omarchy-apply-system accepts --profile"
grep -Fq 'default|child)' "$apply_system" || fail "omarchy-apply-system allows only the default and child profiles"
grep -Fq 'OMARCHY_PROFILE_FILE:-/etc/omarchy/profile' "$apply_system" || fail "omarchy-apply-system writes the marker omarchy-profile-child reads"
grep -Fq 'OMARCHY_PROFILE_FILE:-/etc/omarchy/profile' "$predicate" || fail "omarchy-profile-child reads the marker omarchy-apply-system writes"
grep -Fq 'export OMARCHY_INSTALL_PROFILE=' "$apply_system" || fail "omarchy-apply-system exports the profile for the install leaves"
pass "omarchy-apply-system records the install profile where the predicate reads it"

# The child package list exists for the ISO to vendor. Phase 1 fills it with
# the extra apps a child install pacstraps on top of the base set.

child_packages="$ROOT/install/omarchy-child.packages"
[[ -f $child_packages ]] || fail "install/omarchy-child.packages ships"
mapfile -t child_pkgs < <(grep -vE '^[[:space:]]*(#|$)' "$child_packages")
(( ${#child_pkgs[@]} > 0 )) || fail "install/omarchy-child.packages lists the child app set"
printf '%s\n' "${child_pkgs[@]}" | grep -qxF gcompris-qt || fail "the child app set includes gcompris-qt"
printf '%s\n' "${child_pkgs[@]}" | grep -qxF leocad || fail "the child app set includes leocad"
if printf '%s\n' "${child_pkgs[@]}" | grep -qxF supertuxkart; then
  fail "the child app set does not include SuperTuxKart"
fi
grep -Fq 'omarchy-child.packages' "$ROOT/bin/omarchy-reinstall-pkgs" || fail "omarchy-reinstall-pkgs includes the child list"
grep -Fq 'omarchy-profile-child' "$ROOT/bin/omarchy-reinstall-pkgs" || fail "omarchy-reinstall-pkgs includes the child list only on child installs"
pass "the child package list is wired for the ISO and for reinstalls"

child_apps="$ROOT/install/omarchy-child-applications"
[[ -d $child_apps ]] || fail "install/omarchy-child-applications ships"
  for child_launcher in "Khan Academy" Scratch Grokipedia Wikipedia; do
  [[ -f "$child_apps/${child_launcher}.desktop" ]] || fail "child launcher '$child_launcher' is a shipped desktop file"
  grep -Fq omarchy-launch-webapp "$child_apps/${child_launcher}.desktop" ||
    fail "child launcher '$child_launcher' uses omarchy-launch-webapp"
  icon=$(sed -n 's/^Icon=//p' "$child_apps/${child_launcher}.desktop" | head -1)
  [[ -n $icon ]] || fail "child launcher '$child_launcher' sets Icon="
  icon_matched=0
  for icon_file in "$ROOT/applications/icons/"*; do
    [[ -f $icon_file ]] || continue
    icon_base=${icon_file##*/}
    icon_base=${icon_base%.*}
    icon_slug=$(printf '%s\n' "$icon_base" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]\+/-/g; s/^-//; s/-$//')
    if [[ $icon_slug == "$icon" ]]; then
      icon_matched=1
      break
    fi
  done
  (( icon_matched )) || fail "child launcher '$child_launcher' Icon=$icon has a matching file under applications/icons/"
done
grep -Fq 'omarchy-child-applications' "$ROOT/bin/omarchy-refresh-applications" ||
  fail "omarchy-refresh-applications copies the child-only launchers"
pass "the child-only launcher directory is wired into refresh"

hidden="$ROOT/install/omarchy-child-hidden-applications"
[[ -f $hidden ]] || fail "install/omarchy-child-hidden-applications ships"
hidden_count=0
battlenet_hidden=0
while IFS= read -r name || [[ -n $name ]]; do
  [[ -z $name || $name == \#* ]] && continue
  [[ -f "$ROOT/applications/${name}.desktop" || -f "$ROOT/default/applications/${name}.desktop" ]] || fail "hidden launcher '$name' is a shipped desktop file"
  if [[ $name == "battlenet" ]]; then
    battlenet_hidden=1
  fi
  hidden_count=$((hidden_count + 1))
done <"$hidden"
(( hidden_count > 0 )) || fail "install/omarchy-child-hidden-applications lists launchers to drop"
(( battlenet_hidden == 1 )) || fail "the hidden launcher list includes Battle.net"
grep -Fq 'omarchy-child-hidden-applications' "$ROOT/bin/omarchy-refresh-applications" ||
  fail "omarchy-refresh-applications reads the hidden launcher list"
pass "the child hidden-launcher list names shipped desktop files"

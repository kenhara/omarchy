#!/bin/bash
#
# omarchy-parent apps records root-owned show/hide overrides so a child
# launcher hide survives refresh and updates.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

apps="$ROOT/bin/omarchy-parent-apps"
helper="$ROOT/install/helpers/parent-apps.sh"

[[ -x $apps ]] || fail "omarchy-parent-apps is executable"
grep -q '^# omarchy:summary=' "$apps" || fail "omarchy-parent-apps carries command metadata"
grep -q '^# omarchy:requires-sudo=true' "$apps" || fail "omarchy-parent-apps is marked as requiring sudo"
help_output=$(bash "$apps" --help)
[[ $help_output == *"omarchy-parent apps"* && $help_output == *"show"* ]] ||
  fail "omarchy-parent-apps --help prints usage without elevating"
pass "omarchy-parent-apps answers --help before asking for a password"

grep -Fq 'parent-apps-show' "$ROOT/bin/omarchy-refresh-applications" \
  || grep -Fq 'parent-apps-show' "$helper" ||
  fail "refresh-applications honours the parent show override"
grep -Fq 'parent_apps_refresh_home' "$ROOT/bin/omarchy-refresh-applications" ||
  fail "omarchy-refresh-applications calls the parent-apps helper"
pass "refresh-applications reads the parent override files"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export OMARCHY_PATH="$ROOT"
export OMARCHY_PARENT_APPS_SHOW="$test_tmp/show"
export OMARCHY_PARENT_APPS_HIDE="$test_tmp/hide"
export OMARCHY_PARENT_APPS_SHIPPED="$ROOT/install/omarchy-child-hidden-applications"
source "$helper"

[[ $(parent_apps_normalize "YouTube") == YouTube ]] || fail "normalize keeps YouTube"
[[ $(parent_apps_normalize "  Google Contacts  ") == "Google Contacts" ]] || fail "normalize trims Google Contacts"
[[ $(parent_apps_normalize "X") == X ]] || fail "normalize keeps the single-letter X launcher"
if parent_apps_normalize "../evil" >/dev/null; then
  fail "normalize rejects a path"
fi
if parent_apps_normalize "YouTube.desktop" >/dev/null; then
  fail "normalize rejects a .desktop suffix"
fi
pass "launcher names are validated"

parent_apps_add "$PARENT_APPS_SHOW" YouTube
parent_apps_add "$PARENT_APPS_SHOW" YouTube
[[ $(parent_apps_read "$PARENT_APPS_SHOW") == YouTube ]] || fail "show is idempotent"
parent_apps_add "$PARENT_APPS_HIDE" YouTube
parent_apps_remove "$PARENT_APPS_SHOW" YouTube
[[ -z $(parent_apps_read "$PARENT_APPS_SHOW") ]] || fail "removing from show clears it"
[[ $(parent_apps_read "$PARENT_APPS_HIDE") == YouTube ]] || fail "hide records YouTube"
parent_apps_has WhatsApp "$PARENT_APPS_SHIPPED" || fail "the shipped list still hides WhatsApp"
parent_apps_should_hide WhatsApp || fail "WhatsApp stays hidden without a show override"
parent_apps_add "$PARENT_APPS_SHOW" WhatsApp
parent_apps_should_hide WhatsApp && fail "a show override stops WhatsApp being hidden"
parent_apps_should_hide YouTube || fail "a hide override hides YouTube"
pass "show and hide overrides compose with the shipped list"

printf 'youtube.com\n' >"$test_tmp/parent-sites"
export OMARCHY_PARENT_SITES_FILE="$test_tmp/parent-sites"
# hint is in the command; assert the sites file is what it greps
grep -qx youtube.com "$OMARCHY_PARENT_SITES_FILE" || fail "the YouTube hint can see a blocked youtube.com"
pass "showing YouTube can notice a blocked youtube.com"

if ! unshare --user --map-root-user true 2>/dev/null; then
  pass "no unprivileged user namespace; skipping the omarchy-parent-apps command probes"
  exit 0
fi

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/omarchy-profile-child" <<'SH'
#!/bin/bash
[[ ${STUB_PROFILE:-child} == child ]]
SH
cat >"$stub_bin/getent" <<'SH'
#!/bin/bash
[[ $2 == kid ]] && printf 'kid:x:1000:1000::/tmp/kid:/bin/bash\n'
SH
cat >"$stub_bin/runuser" <<'SH'
#!/bin/bash
printf 'runuser %s\n' "$*" >>"$RUNUSER_LOG"
SH
chmod +x "$stub_bin"/*

rm -f "$test_tmp/show" "$test_tmp/hide"
out=$(unshare --user --map-root-user env \
  OMARCHY_PATH="$ROOT" \
  OMARCHY_PARENT_APPS_SHOW="$test_tmp/show" \
  OMARCHY_PARENT_APPS_HIDE="$test_tmp/hide" \
  OMARCHY_PARENT_APPS_SHIPPED="$ROOT/install/omarchy-child-hidden-applications" \
  OMARCHY_PARENT_SITES_FILE="$test_tmp/parent-sites" \
  PATH="$stub_bin:$PATH" \
  RUNUSER_LOG="$test_tmp/runuser" \
  bash "$apps" show YouTube)
[[ $out == *"Shown: YouTube"* ]] || fail "show reports the launcher" "$out"
[[ $out == *"youtube.com is still blocked"* ]] || fail "show hints when youtube.com is blocked" "$out"
grep -qx YouTube "$test_tmp/show" || fail "show records YouTube"
out=$(unshare --user --map-root-user env \
  OMARCHY_PATH="$ROOT" \
  OMARCHY_PARENT_APPS_SHOW="$test_tmp/show" \
  OMARCHY_PARENT_APPS_HIDE="$test_tmp/hide" \
  OMARCHY_PARENT_APPS_SHIPPED="$ROOT/install/omarchy-child-hidden-applications" \
  PATH="$stub_bin:$PATH" \
  RUNUSER_LOG="$test_tmp/runuser" \
  bash "$apps" hide YouTube)
[[ $out == *"Hidden: YouTube"* ]] || fail "hide reports the launcher" "$out"
grep -qx YouTube "$test_tmp/hide" || fail "hide records YouTube"
! grep -qx YouTube "$test_tmp/show" || fail "hide takes YouTube off the show list"
if STUB_PROFILE=default PATH="$stub_bin:$PATH" OMARCHY_PATH="$ROOT" \
  unshare --user --map-root-user bash "$apps" show YouTube >/dev/null 2>&1; then
  fail "apps refuses to run outside the child profile"
fi
pass "omarchy-parent apps show and hide as root and refuse a non-child install"

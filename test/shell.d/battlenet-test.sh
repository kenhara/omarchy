#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

install_script="$ROOT/bin/omarchy-install-gaming-battlenet"

[[ ! -f $ROOT/applications/battlenet.desktop ]] || fail "Battle.net launcher is not part of default application refresh"
[[ -f $ROOT/default/applications/battlenet.desktop ]] || fail "Battle.net launcher template is available to the installer"
grep -F '$OMARCHY_PATH/default/applications/battlenet.desktop' "$install_script" >/dev/null ||
  fail "Battle.net installer installs the launcher from the installer-only template"
grep -qxF battlenet "$ROOT/install/omarchy-child-hidden-applications" ||
  fail "a child profile hides the Battle.net launcher"
grep -Fq 'omarchy-profile-child' "$install_script" ||
  fail "the Battle.net installer refuses on a child profile"
grep -Fq 'not available on a child install' "$install_script" ||
  fail "the Battle.net installer names the child-install refusal"
grep -Fq child_require_install "$install_script" &&
  fail "the Battle.net installer does not ask for the parent password on a child profile" || true

child_marker=$(mktemp)
printf 'child\n' >"$child_marker"
sudo_log=$(mktemp)
cat >"$test_tmp/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_SUDO_LOG"
exit 0
SH
chmod +x "$test_tmp/sudo"
: >"$sudo_log"
if PATH="$test_tmp:$PATH" OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$child_marker" OMARCHY_TEST_SUDO_LOG="$sudo_log" \
  bash "$install_script" >/dev/null 2>"$test_tmp/battlenet.err"; then
  fail "the Battle.net installer exits non-zero on a child profile"
fi
grep -Fq 'not available on a child install' "$test_tmp/battlenet.err" ||
  fail "the Battle.net installer explains the child-install refusal" "$(cat "$test_tmp/battlenet.err")"
[[ ! -s $sudo_log ]] || fail "the Battle.net installer does not prompt sudo on a child profile" "$(cat "$sudo_log")"
rm -f "$child_marker" "$sudo_log"

pass "Battle.net launcher is only installed by the Battle.net installer"

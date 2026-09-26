#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
stub_bin="$test_tmp/bin"
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$stub_bin"

approved="$test_tmp/approved"
profile="$test_tmp/profile"
printf 'child\n' >"$profile"
install -m 644 /dev/null "$approved"

sudo_log="$test_tmp/sudo.log"
cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SUDO_LOG"
[[ $1 == "-k" ]] && exit 0
exit 1
SH
chmod +x "$stub_bin/sudo"

status=0
HOME="$test_tmp/home" OMARCHY_PROFILE_FILE="$profile" \
  OMARCHY_PATH="$ROOT" PATH="$stub_bin:$ROOT/bin:$PATH" \
  APPROVED_FILE="$approved" SUDO_LOG="$sudo_log" \
  bash -c '
    source "$OMARCHY_PATH/install/helpers/plugin-parent-gate.sh"
    PLUGIN_PARENT_APPROVED_FILE="$APPROVED_FILE"
    register_parent_approved_plugin acme.evil
  ' >/dev/null 2>&1 || status=$?
(( status != 0 )) || fail "register must fail when sudo rejects the parent password"
grep -qxF 'acme.evil' "$approved" && fail "register must not change the approved list without successful sudo"
grep -qxF -- '-k' "$sudo_log" ||
  fail "register drops the sudo ticket after a refused approval" "$(cat "$sudo_log")"
pass "the kid cannot register a plugin id without a successful sudo"

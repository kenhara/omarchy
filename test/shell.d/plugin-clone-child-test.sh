#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/home/.config/omarchy" "$TMPDIR/bin"

child_profile="$TMPDIR/profile"
approved_file="$TMPDIR/approved"
sudo_log="$TMPDIR/sudo.log"
calls="$TMPDIR/calls"
sudo_fail="$TMPDIR/sudo.fail"

printf 'child\n' >"$child_profile"
install -m 644 /dev/null "$approved_file"

cat >"$TMPDIR/bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SUDO_LOG"
case "$*" in
  -k)
    exit 0
    ;;
  omarchy-plugin-approve*)
    if [[ -f $SUDO_FAIL ]]; then
      exit 1
    fi
    id="${@: -1}"
    grep -qxF "$id" "$OMARCHY_TEST_APPROVED_FILE" 2>/dev/null ||
      printf '%s\n' "$id" >>"$OMARCHY_TEST_APPROVED_FILE"
    exit 0
    ;;
esac
exit 1
SH

cat >"$TMPDIR/bin/omarchy-shell" <<'SH'
#!/bin/bash
if [[ $* == *"listShellConfig"* ]]; then
  printf '%s\n' '{"bar":{"layout":{"left":[],"center":[{"id":"omarchy.clock"}],"right":[]}}}'
elif [[ $* == *"listPlugins"* ]]; then
  find "$HOME/.config/omarchy/plugins" -mindepth 2 -maxdepth 2 -name manifest.json -print0 2>/dev/null |
    xargs -0 -r jq -s 'map({id: .id, enabled: true})'
elif [[ $* == *"enablePlugin"* || $* == *"setPluginEnabled"* || $* == *"rescanPlugins"* ]]; then
  printf 'omarchy-shell %s\n' "$*" >>"$FAKE_CALLS"
  printf 'ok\n'
fi
exit 0
SH

cat >"$TMPDIR/bin/omarchy-notification-send" <<'SH'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"$FAKE_CALLS"
SH
chmod +x "$TMPDIR/bin/"*

run_clone() {
  HOME="$TMPDIR/home" USER=tester OMARCHY_PATH="$ROOT" \
    OMARCHY_PROFILE_FILE="$child_profile" \
    OMARCHY_TEST_APPROVED_FILE="$approved_file" \
    SUDO_LOG="$sudo_log" SUDO_FAIL="$sudo_fail" FAKE_CALLS="$calls" \
    PATH="$TMPDIR/bin:$ROOT/bin:$PATH" \
    omarchy-plugin-clone "$@"
}

plugins_dir="$TMPDIR/home/.config/omarchy/plugins"
: >"$sudo_log"
touch "$sudo_fail"
clone_fail_status=0
run_clone omarchy.clock >/dev/null 2>&1 || clone_fail_status=$?
(( clone_fail_status != 0 )) ||
  fail "clone must fail when parent approval is refused"
[[ ! -e $plugins_dir/tester.clock ]] ||
  fail "a refused parent sudo must not leave the clone target"
leftover_clone=$(find "$plugins_dir" -mindepth 1 -maxdepth 1 2>/dev/null || true)
[[ -z $leftover_clone ]] ||
  fail "a refused parent sudo must remove the partial clone" "$leftover_clone"
grep -Fq 'omarchy-plugin-approve' "$sudo_log" ||
  fail "clone on a child install asks for parent approval"
grep -qxF -- '-k' "$sudo_log" ||
  fail "clone drops the sudo ticket after a refused approval" "$(cat "$sudo_log")"
pass "clone removes a partial clone when parent approval fails"

rm -f "$sudo_fail"
: >"$sudo_log"
: >"$calls"
run_clone omarchy.clock >/dev/null ||
  fail "clone should succeed after parent approval"
[[ -d $plugins_dir/tester.clock ]] ||
  fail "clone publishes the target after a successful approval"
grep -qxF -- '-k' "$sudo_log" ||
  fail "clone drops the sudo ticket after a successful approval" "$(cat "$sudo_log")"
pass "clone on a child install drops the sudo ticket after approval"

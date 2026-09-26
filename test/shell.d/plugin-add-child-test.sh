#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
mkdir -p "$TMPDIR/bin" "$TMPDIR/home/.config/omarchy/plugins"

child_profile="$TMPDIR/profile"
approved_file="$TMPDIR/approved"
sudo_log="$TMPDIR/sudo.log"
calls="$TMPDIR/calls"
incoming="$TMPDIR/incoming"
sudo_fail="$TMPDIR/sudo.fail"

printf 'child\n' >"$child_profile"
install -m 644 /dev/null "$approved_file"

write_plugin() {
  local dir="$1" id="$2"
  mkdir -p "$dir"
  cat >"$dir/manifest.json" <<JSON
{"schemaVersion":1,"id":"$id","name":"$id","version":"1.0.0","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}
JSON
  printf 'import QtQuick\nItem {}\n' >"$dir/W.qml"
}

write_plugin "$incoming" acme.test
git -C "$incoming" init -q
git -C "$incoming" add .
git -C "$incoming" -c user.name=Test -c user.email=test@example.com commit -qm init

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
chmod +x "$TMPDIR/bin/sudo"

cat >"$TMPDIR/bin/omarchy-shell" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_CALLS"
printf 'ok\n'
SH
chmod +x "$TMPDIR/bin/omarchy-shell"

cat >"$TMPDIR/bin/omarchy-plugin-list" <<'SH'
#!/bin/bash
printf '[{"id":"acme.test"}]\n'
SH
chmod +x "$TMPDIR/bin/omarchy-plugin-list"

run_add() {
  HOME="$TMPDIR/home" OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$child_profile" \
    OMARCHY_TEST_APPROVED_FILE="$approved_file" SUDO_LOG="$sudo_log" \
    SUDO_FAIL="$sudo_fail" OMARCHY_TEST_CALLS="$calls" \
    PATH="$TMPDIR/bin:$ROOT/bin:$PATH" \
    omarchy-plugin-add "$@"
}

: >"$sudo_log"
touch "$sudo_fail"
add_fail_output=$(run_add "$incoming" --yes --enable 2>&1) || true
[[ ! -e $TMPDIR/home/.config/omarchy/plugins/acme.test ]] ||
  fail "a refused parent sudo must not leave the plugin installed"
leftover_add=$(find "$TMPDIR/home/.config/omarchy/plugins" -mindepth 1 -maxdepth 1 2>/dev/null || true)
[[ -z $leftover_add ]] ||
  fail "a refused parent sudo must leave nothing installed" "$leftover_add"
[[ $add_fail_output != *"already installed"* ]] ||
  fail "a refused parent sudo must not report the plugin as already installed"
grep -Fq 'omarchy-plugin-approve' "$sudo_log" ||
  fail "a refused add still asks for parent approval"
grep -qxF -- '-k' "$sudo_log" ||
  fail "plugin add drops the sudo ticket after a refused approval" "$(cat "$sudo_log")"
: >"$sudo_log"
add_retry_output=$(run_add "$incoming" --yes --enable 2>&1) || true
[[ $add_retry_output != *"already installed"* ]] ||
  fail "retrying after a refused sudo must not say the plugin is already installed"
[[ ! -e $TMPDIR/home/.config/omarchy/plugins/acme.test ]] ||
  fail "retrying a refused add must still leave nothing installed"
pass "plugin add rolls back when parent approval sudo fails"

rm -f "$sudo_fail"
: >"$sudo_log"
: >"$calls"
add_ok_output=$(run_add "$incoming" --yes --enable 2>&1) ||
  fail "plugin add --enable should succeed after parent approval" "$add_ok_output"

(( $(grep -c 'omarchy-plugin-approve' "$sudo_log") == 1 )) ||
  fail "plugin add --enable on a child install registers through sudo once" "$(cat "$sudo_log")"
grep -qxF -- '-k' "$sudo_log" ||
  fail "plugin add drops the sudo ticket when it finishes" "$(cat "$sudo_log")"
grep -Fqx 'shell enablePlugin acme.test {}' "$calls" ||
  fail "plugin add --enable still enables in-process after registration"
pass "plugin add --enable on a child install uses one sudo registration and in-process enable"

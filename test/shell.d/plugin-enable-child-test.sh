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

run_enable() {
  HOME="$TMPDIR/home" OMARCHY_PATH="$ROOT" OMARCHY_PROFILE_FILE="$child_profile" \
    OMARCHY_TEST_APPROVED_FILE="$approved_file" SUDO_LOG="$sudo_log" \
    OMARCHY_TEST_CALLS="$calls" PATH="$TMPDIR/bin:$ROOT/bin:$PATH" \
    omarchy-plugin-enable "$@"
}

mkdir -p "$TMPDIR/home/.config/omarchy/plugins/acme.test"
printf '{"schemaVersion":1,"id":"acme.test","name":"Test","version":"1","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}\n' \
  >"$TMPDIR/home/.config/omarchy/plugins/acme.test/manifest.json"

run_enable acme.test --section right >/dev/null
grep -Fq 'omarchy-plugin-approve' "$sudo_log" ||
  fail "plugin enable on a child install registers through sudo" "$(cat "$sudo_log")"
grep -qxF -- '-k' "$sudo_log" ||
  fail "plugin enable drops the sudo ticket when it finishes" "$(cat "$sudo_log")"
grep -qxF 'acme.test' "$approved_file" || fail "plugin enable registers the id for shell scan"
grep -Fqx 'shell rescanPlugins' "$calls" || fail "plugin enable rescans after registering on a child install"
grep -Fqx 'shell enablePlugin acme.test {"section":"right"}' "$calls" ||
  fail "plugin enable still reaches the shell after registration"
pass "plugin enable on a child install requires sudo and registers the plugin"

: >"$sudo_log"
: >"$calls"
run_enable omarchy.tailscale >/dev/null
if [[ -s $sudo_log ]]; then
  fail "enabling a built-in on a child profile must never call sudo" "$(cat "$sudo_log")"
fi
grep -Fqx 'shell enablePlugin omarchy.tailscale {}' "$calls" ||
  fail "enabling a built-in on a child profile still reaches shell enablePlugin"
pass "enabling a built-in on a child profile never calls sudo"

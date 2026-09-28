#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

plugins_dir="$test_tmp/plugins"
approved_file="$test_tmp/approved"
profile_file="$test_tmp/profile"
stub_bin="$test_tmp/bin"
sudo_log="$test_tmp/sudo.log"

mkdir -p "$plugins_dir/acme.weather" "$stub_bin"
install -m 644 /dev/null "$approved_file"
chmod 644 "$approved_file"

write_plugin() {
  local id="$1" dir="${2:-$1}"
  mkdir -p "$plugins_dir/$dir"
  printf '{"schemaVersion":1,"id":"%s","name":"%s","version":"1.0.0","kinds":["bar-widget"],"entryPoints":{"barWidget":"W.qml"}}\n' "$id" "$id" \
    >"$plugins_dir/$dir/manifest.json"
}

write_plugin acme.weather
write_plugin acme.other

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SUDO_LOG"
case "$*" in
  -k)
    exit 0
    ;;
  omarchy-plugin-approve*)
    if [[ -f ${SUDO_FAIL:-} ]]; then
      exit 1
    fi
    id="${@: -1}"
    grep -qxF "$id" "$APPROVED_FILE" 2>/dev/null ||
      printf '%s\n' "$id" >>"$APPROVED_FILE"
    exit 0
    ;;
esac
exit 1
SH
chmod +x "$stub_bin/sudo"

source_helper() {
  local cmd="$1"
  shift
  HOME="$test_tmp/home" OMARCHY_PROFILE_FILE="$profile_file" \
    SUDO_LOG="$sudo_log" ROOT="$ROOT" PATH="$stub_bin:$ROOT/bin:$PATH" \
    APPROVED_FILE="$approved_file" PROFILE_FILE="$profile_file" \
    PLUGIN_PARENT_APPROVED_FILE="$approved_file" \
    SUDO_FAIL="${SUDO_FAIL:-}" \
    bash -c '
      source "$ROOT/install/helpers/plugin-parent-gate.sh"
      PLUGIN_PARENT_APPROVED_FILE="$APPROVED_FILE"
      PLUGIN_CHILD_PROFILE_FILE="$PROFILE_FILE"
      '"$cmd" bash "$@"
}

grep -Fq 'PLUGIN_PARENT_APPROVED_FILE="/etc/omarchy/plugins-parent-approved"' \
  "$ROOT/install/helpers/plugin-parent-gate.sh" ||
  fail "the parent-approved list is hardcoded under /etc/omarchy"
grep -Fq 'PLUGIN_CHILD_PROFILE_FILE="/etc/omarchy/profile"' \
  "$ROOT/install/helpers/plugin-parent-gate.sh" ||
  fail "the child scan reads /etc/omarchy/profile directly"
pass "the parent-approved list lives on a root-owned path"

if bash "$ROOT/bin/omarchy-plugin-approve" acme.test >/dev/null 2>&1; then
  fail "omarchy-plugin-approve refuses to run without sudo"
fi
pass "omarchy-plugin-approve runs only as root"

grep -q 'OMARCHY_PLUGIN_PARENT_APPROVED_FILE' "$ROOT/bin/omarchy-plugin-approve" &&
  fail "omarchy-plugin-approve must not honor an env override of the approved file"
grep -Fq 'file="/etc/omarchy/plugins-parent-approved"' "$ROOT/bin/omarchy-plugin-approve" ||
  fail "omarchy-plugin-approve writes the fixed /etc path"
pass "omarchy-plugin-approve honors no environment overrides"

printf 'default\n' >"$profile_file"
output=$(source_helper 'scan_thirdparty_plugin_manifests "$1"' "$plugins_dir")
grep -qxF "$plugins_dir/acme.weather/manifest.json" <<<"$output" ||
  fail "default installs scan every third-party plugin"
grep -qxF "$plugins_dir/acme.other/manifest.json" <<<"$output" ||
  fail "default installs scan every third-party plugin directory"
pass "plugin scan leaves default installs unchanged"

printf 'child\n' >"$profile_file"
output=$(source_helper 'scan_thirdparty_plugin_manifests "$1"' "$plugins_dir")
[[ -z $output ]] || fail "child installs hide unapproved third-party plugins"

printf 'acme.weather\n' >>"$approved_file"
output=$(source_helper 'scan_thirdparty_plugin_manifests "$1"' "$plugins_dir")
grep -qxF "$plugins_dir/acme.weather/manifest.json" <<<"$output" ||
  fail "child installs load parent-approved plugins"
grep -qxF "$plugins_dir/acme.other/manifest.json" <<<"$output" &&
  fail "child installs still hide unapproved plugins"
pass "plugin scan only exposes parent-approved ids on child installs"

write_plugin acme.weather acme.impostor
output=$(source_helper 'scan_thirdparty_plugin_manifests "$1"' "$plugins_dir")
grep -qxF "$plugins_dir/acme.impostor/manifest.json" <<<"$output" &&
  fail "child installs must not load a second directory that impersonates an approved id"
grep -qxF "$plugins_dir/acme.weather/manifest.json" <<<"$output" ||
  fail "the real approved directory still loads when an impostor exists"
pass "child scan requires directory name to match the manifest id"

decoy_approved="$test_tmp/decoy-approved"
printf 'acme.other\n' >"$decoy_approved"
output=$(
  HOME="$test_tmp/home" OMARCHY_PROFILE_FILE="$test_tmp/not-child" \
    OMARCHY_PLUGIN_PARENT_APPROVED_FILE="$decoy_approved" \
    ROOT="$ROOT" APPROVED_FILE="$approved_file" PROFILE_FILE="$profile_file" \
    bash -c '
      source "$ROOT/install/helpers/plugin-parent-gate.sh"
      PLUGIN_PARENT_APPROVED_FILE="$APPROVED_FILE"
      PLUGIN_CHILD_PROFILE_FILE="$PROFILE_FILE"
      scan_thirdparty_plugin_manifests "$1"
    ' bash "$plugins_dir"
)
grep -qxF "$plugins_dir/acme.other/manifest.json" <<<"$output" &&
  fail "OMARCHY_PLUGIN_PARENT_APPROVED_FILE must not relocate the approved list"
grep -qxF "$plugins_dir/acme.weather/manifest.json" <<<"$output" ||
  fail "scan still uses the hardcoded approved list after an env override"
pass "approved-file environment override does not relocate the child scan"

output=$(
  HOME="$test_tmp/home" OMARCHY_PROFILE_FILE="$test_tmp/not-child" \
    ROOT="$ROOT" APPROVED_FILE="$approved_file" PROFILE_FILE="$profile_file" \
    bash -c '
      source "$ROOT/install/helpers/plugin-parent-gate.sh"
      PLUGIN_PARENT_APPROVED_FILE="$APPROVED_FILE"
      PLUGIN_CHILD_PROFILE_FILE="$PROFILE_FILE"
      scan_thirdparty_plugin_manifests "$1"
    ' bash "$plugins_dir"
)
[[ -n $output ]] || fail "OMARCHY_PROFILE_FILE must not disable the child scan"
grep -qxF "$plugins_dir/acme.other/manifest.json" <<<"$output" &&
  fail "child scan still hides unapproved ids when OMARCHY_PROFILE_FILE is forged"
pass "OMARCHY_PROFILE_FILE does not disable the child plugin scan"

if grep -Eq '^[[:space:]]*trap ' "$ROOT/install/helpers/plugin-parent-gate.sh"; then
  fail "sourced parent-gate helper must not set traps"
fi
pass "parent-gate helper never installs an EXIT trap"

: >"$sudo_log"
source_helper 'register_parent_approved_plugin "$1"' acme.new
grep -Fq 'omarchy-plugin-approve' "$sudo_log" ||
  fail "registering an approved id goes through sudo omarchy-plugin-approve"
grep -qxF -- '-k' "$sudo_log" ||
  fail "register drops the sudo ticket when it finishes" "$(cat "$sudo_log")"
grep -qxF 'acme.new' "$approved_file" || fail "register persists the id"
pass "register_parent_approved_plugin appends through sudo omarchy-plugin-approve"

caller_trap="$test_tmp/caller-trap-ran"
sudo_fail="$test_tmp/sudo.fail"
: >"$sudo_log"
touch "$sudo_fail"
register_fail_status=0
HOME="$test_tmp/home" OMARCHY_PROFILE_FILE="$profile_file" \
  SUDO_LOG="$sudo_log" ROOT="$ROOT" PATH="$stub_bin:$ROOT/bin:$PATH" \
  APPROVED_FILE="$approved_file" PROFILE_FILE="$profile_file" \
  SUDO_FAIL="$sudo_fail" \
  bash -c '
    source "$ROOT/install/helpers/plugin-parent-gate.sh"
    PLUGIN_PARENT_APPROVED_FILE="$APPROVED_FILE"
    PLUGIN_CHILD_PROFILE_FILE="$PROFILE_FILE"
    trap "touch \"$1\"" EXIT
    register_parent_approved_plugin acme.fail
  ' bash "$caller_trap" >/dev/null 2>&1 || register_fail_status=$?
(( register_fail_status != 0 )) ||
  fail "register must fail when sudo rejects the parent password"
[[ -f $caller_trap ]] ||
  fail "sourced register must not replace the caller EXIT trap"
grep -Fq 'omarchy-plugin-approve' "$sudo_log" ||
  fail "a refused register still invokes sudo omarchy-plugin-approve"
grep -qxF -- '-k' "$sudo_log" ||
  fail "register drops the sudo ticket after a refused approval" "$(cat "$sudo_log")"
grep -qxF 'acme.fail' "$approved_file" &&
  fail "a refused register must not persist the id"
pass "register drops the sudo ticket and keeps the caller EXIT trap on failure"

grep -Fq 'scan_thirdparty_plugin_manifests' "$ROOT/bin/omarchy-plugin-catalog" ||
  fail "omarchy-plugin-catalog must use the child scan so bar selection cannot offer unloaded bars"
pass "plugin catalog walks user plugins through the child scan"

grep -Fq '${OMARCHY_PATH:-/usr/share/omarchy}' "$ROOT/shell/services/PluginRegistry.qml" &&
  fail "PluginRegistry must not default OMARCHY_PATH"
grep -Fq 'source \"$2/install/helpers/plugin-parent-gate.sh\"' "$ROOT/shell/services/PluginRegistry.qml" ||
  fail "PluginRegistry must source the parent-gate helper with a positional Omarchy path"
pass "PluginRegistry sources the helper without defaulting OMARCHY_PATH"

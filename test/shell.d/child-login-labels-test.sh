#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

helper="$ROOT/install/helpers/child-login-labels.sh"
apply_lock="$ROOT/bin/omarchy-apply-lock"
main_qml="$ROOT/default/sddm/omarchy/Main.qml"
lock_view="$ROOT/shell/plugins/lock/LockView.qml"
lock_service="$ROOT/shell/plugins/lock/Service.qml"

grep -Fq 'omarchy_apply_child_login_labels' "$apply_lock" ||
  fail "omarchy-apply-lock writes child login labels"
grep -Fq 'omarchy_remove_child_login_labels' "$apply_lock" ||
  fail "omarchy-apply-lock removes child login labels outside the profile"
grep -Fq 'omarchy_apply_child_login_labels' "$ROOT/bin/omarchy-provision-owner" ||
  fail "first-boot configure_login refreshes child login labels"
grep -Fq 'showChildLoginLabels' "$main_qml" ||
  fail "the SDDM theme reads child login labels from theme.conf.user"
grep -Fq 'loginDisplayName' "$lock_view" ||
  fail "the lock screen shows the kid display name on child installs"
grep -Fq 'child-login.conf' "$lock_service" ||
  fail "the lock service reads /etc/omarchy/child-login.conf"
pass "child login label wiring is present"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

child_login_conf="$test_tmp/child-login.conf"
sddm_theme_conf="$test_tmp/theme.conf.user"
stub_bin="$test_tmp/bin"
pam_dir="$test_tmp/pam.d"
mkdir -p "$stub_bin" "$pam_dir"

cat >"$stub_bin/omarchy-profile-child" <<'STUB'
#!/bin/bash
[[ ${STUB_PROFILE:-default} == child ]]
STUB
chmod +x "$stub_bin/omarchy-profile-child"

cat >"$stub_bin/getent" <<'STUB'
#!/bin/bash
if [[ $1 == passwd && $2 == charli ]]; then
  printf '%s\n' 'charli:x:1000:1000:Charli:/home/charli:/bin/bash'
  exit 0
fi
exit 2
STUB
chmod +x "$stub_bin/getent"

for cmd in cat cp grep rm tee; do
  ln -s "$(command -v "$cmd")" "$stub_bin/$cmd"
done

source "$helper"

display=$(OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" bash -c 'source "$1"; omarchy_child_login_display_name charli' _ "$helper")
[[ $display == Charli ]] || fail "display name prefers GECOS over username" "$display"

display=$(OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" bash -c 'source "$1"; omarchy_child_login_display_name nobody' _ "$helper")
[[ $display == nobody ]] || fail "display name falls back to the username" "$display"

hint=$(bash -c 'source "$1"; omarchy_child_login_password_hint Charli' _ "$helper")
[[ $hint == "Charli's password or a parent password" ]] || fail "password hint names the kid" "$hint"

TEST_PROFILE=child OMARCHY_CHILD_LOGIN_CONF="$child_login_conf" OMARCHY_SDDM_THEME_CONF_USER="$sddm_theme_conf" \
  OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" STUB_PROFILE=child \
  bash -c 'source "$1"; omarchy_apply_child_login_labels charli' _ "$helper"

grep -Fx 'display_name=Charli' "$child_login_conf" >/dev/null ||
  fail "apply writes the lock-screen label file"
grep -Fx "password_hint=Charli's password or a parent password" "$child_login_conf" >/dev/null ||
  fail "apply writes the password hint for the lock screen"
grep -Fx 'accountDisplayName=Charli' "$sddm_theme_conf" >/dev/null ||
  fail "apply writes SDDM theme.conf.user"
grep -Fx "passwordHint=Charli's password or a parent password" "$sddm_theme_conf" >/dev/null ||
  fail "apply writes the SDDM password hint"
pass "apply writes both child login label files"

STUB_PROFILE=default OMARCHY_CHILD_LOGIN_CONF="$child_login_conf" OMARCHY_SDDM_THEME_CONF_USER="$sddm_theme_conf" \
  OMARCHY_PATH="$ROOT" PATH="$stub_bin:$PATH" \
  bash -c 'source "$1"; omarchy_remove_child_login_labels' _ "$helper"
[[ ! -e $child_login_conf && ! -e $sddm_theme_conf ]] ||
  fail "remove clears child login label files outside the profile"
pass "remove clears child login label files"

packaged_sddm=$'#%PAM-1.0\nauth       include system-login\naccount    include system-login\npassword   include system-login\nsession    include system-login'
printf '%s\n' "$packaged_sddm" >"$pam_dir/sddm"

cat >"$stub_bin/sudo" <<SH
#!/bin/bash
args=()
for arg in "\$@"; do args+=("\${arg//\/etc\/pam.d/$pam_dir}"); done
exec "\${args[@]}"
SH
cat >"$stub_bin/omarchy-cmd-present" <<'STUB'
#!/bin/bash
exit 1
STUB
cat >"$stub_bin/omarchy-shell" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$stub_bin/sudo" "$stub_bin/omarchy-cmd-present" "$stub_bin/omarchy-shell"

child_login_conf="$test_tmp/apply-lock-child-login.conf"
sddm_theme_conf="$test_tmp/apply-lock-theme.conf.user"

run_apply_lock() {
  local profile=$1
  OMARCHY_INSTALL_USER=charli OMARCHY_PAM_DIR="$pam_dir" \
    OMARCHY_CHILD_LOGIN_CONF="$child_login_conf" OMARCHY_SDDM_THEME_CONF_USER="$sddm_theme_conf" \
    OMARCHY_PATH="$ROOT" STUB_PROFILE="$profile" PATH="$stub_bin:$PATH" \
    bash "$apply_lock" >/dev/null
}

run_apply_lock child || fail "omarchy-apply-lock writes child login labels on a child install"
grep -Fx 'display_name=Charli' "$child_login_conf" >/dev/null ||
  fail "omarchy-apply-lock writes the lock label file"
grep -Fx 'accountDisplayName=Charli' "$sddm_theme_conf" >/dev/null ||
  fail "omarchy-apply-lock writes SDDM theme.conf.user"

run_apply_lock default || fail "omarchy-apply-lock removes child login labels outside the profile"
[[ ! -e $child_login_conf && ! -e $sddm_theme_conf ]] ||
  fail "omarchy-apply-lock removes child login label files on default installs"
pass "omarchy-apply-lock keeps child login labels profile-gated"

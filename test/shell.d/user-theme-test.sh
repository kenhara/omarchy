#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin" "$test_tmp/home/.config/chromium" "$test_tmp/home/.local/state/omarchy/current"

cat >"$mock_bin/omarchy-theme-set" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_THEME_CALLS"
SH
chmod +x "$mock_bin/omarchy-theme-set"

for command in omarchy-theme-set-pi; do
  cat >"$mock_bin/$command" <<'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$mock_bin/$command"
done

calls="$test_tmp/theme-calls"
adult_marker="$test_tmp/profile-default"
child_marker="$test_tmp/profile-child"
printf 'default\n' >"$adult_marker"
printf 'child\n' >"$child_marker"

touch "$test_tmp/home/.config/chromium/SingletonLock"
HOME="$test_tmp/home" PATH="$mock_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
  OMARCHY_PROFILE_FILE="$adult_marker" OMARCHY_TEST_THEME_CALLS="$calls" \
  bash "$ROOT/install/user/theme.sh"
grep -Fx 'Tokyo Night' "$calls" >/dev/null || fail "user theme setup seeds Tokyo Night when no theme exists"
[[ -f $test_tmp/home/.config/chromium/SingletonLock ]] || fail "runtime user theme setup preserves Chromium's singleton lock"

: >"$calls"
rm -f "$test_tmp/home/.local/state/omarchy/current/theme.name"
HOME="$test_tmp/home" PATH="$mock_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
  OMARCHY_PROFILE_FILE="$child_marker" OMARCHY_TEST_THEME_CALLS="$calls" \
  bash "$ROOT/install/user/theme.sh"
grep -Fx 'Cozy Night' "$calls" >/dev/null || fail "a child profile seeds Cozy Night when no theme exists"
! grep -Fx 'Tokyo Night' "$calls" >/dev/null || fail "a child profile does not seed Tokyo Night"

: >"$calls"
printf 'Solitude\n' >"$test_tmp/home/.local/state/omarchy/current/theme.name"
HOME="$test_tmp/home" PATH="$mock_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
  OMARCHY_PROFILE_FILE="$adult_marker" OMARCHY_TEST_THEME_CALLS="$calls" \
  bash "$ROOT/install/user/theme.sh"
[[ ! -s $calls ]] || fail "user theme setup preserves an existing theme"

: >"$calls"
HOME="$test_tmp/home" PATH="$mock_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
  OMARCHY_PROFILE_FILE="$child_marker" OMARCHY_TEST_THEME_CALLS="$calls" \
  bash "$ROOT/install/user/theme.sh"
[[ ! -s $calls ]] || fail "a child profile preserves an existing theme"

[[ -d $ROOT/themes/cozy-night ]] || fail "the Cozy Night theme ships as themes/cozy-night"

pass "user theme setup only seeds the default theme once"

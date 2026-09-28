#!/bin/bash

source "$(dirname "$0")/base-test.sh"

test_home=$(mktemp -d)
test_bin=$(mktemp -d)
log_file=$(mktemp)
child_profile=$(mktemp)

cleanup() {
  rm -rf "$test_home" "$test_bin" "${default_home:-}"
  rm -f "$log_file" "$child_profile" "${default_profile:-}"
}
trap cleanup EXIT

printf 'child\n' >"$child_profile"

cat >"$test_bin/omarchy-notification-send" <<'EOF'
#!/bin/bash
echo notification >>"$TEST_LOG"
exec_args=()
while (($# > 0)); do
  if [[ $1 == "--exec" ]]; then shift; exec_args=("$@"); break; fi
  shift
done
((${#exec_args[@]})) && echo "exec:${exec_args[*]}" >>"$TEST_LOG"
EOF
chmod +x "$test_bin/omarchy-notification-send"

run_invitation() {
  HOME="${INVITE_HOME:-$test_home}" OMARCHY_PROFILE_FILE="${OMARCHY_PROFILE_FILE:-$child_profile}" \
    PATH="$test_bin:$ROOT/bin:$PATH" TEST_LOG="$log_file" \
    bash "$ROOT/install/user/first-run/kids-sites.sh"
}

run_invitation

[[ -f $test_home/.local/state/omarchy/done/kids-sites-invitation ]] ||
  fail "kids sites invitation records completion on a child install"
(( $(grep -c '^notification$' "$log_file") == 1 )) ||
  fail "kids sites invitation sends one notification on a child install"
grep -qx "exec:omarchy-launch-floating-terminal-with-presentation omarchy-parent sites edit" "$log_file" ||
  fail "kids sites invitation opens the website list for editing"
grep -Fq 'Choose a blocklist or allowlist.' "$ROOT/install/user/first-run/kids-sites.sh" ||
  fail "kids sites invitation offers a blocklist or allowlist"

run_invitation
(( $(grep -c '^notification$' "$log_file") == 1 )) ||
  fail "completed kids sites invitation does not notify again"

pass "kids sites invitation only runs once on a child install"

default_home=$(mktemp -d)
default_profile=$(mktemp)
printf 'default\n' >"$default_profile"
: >"$log_file"
INVITE_HOME="$default_home" OMARCHY_PROFILE_FILE="$default_profile" run_invitation

[[ ! -s $log_file ]] || fail "kids sites invitation stays quiet on a default install"
[[ ! -f $default_home/.local/state/omarchy/done/kids-sites-invitation ]] ||
  fail "kids sites invitation does not mark default installs"

rm -rf "$default_home" "$default_profile"

pass "kids sites invitation skips default installs"

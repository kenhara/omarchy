#!/bin/bash
#
# On a child profile, user-scope app-install entrypoints ask for sudo (the
# parent password) before they install anything, then drop the ticket when
# they finish. Paths that go through sudo pacman or yay (pkg-add, pkg-install,
# AUR add/install) skip that pre-check: that later sudo is the prompt, and
# already-present packages ask nothing. Interactive pkg/AUR installers keep
# using keepalive, which reuses the ticket for nested sudos and drops it on
# exit on a child profile. Default installs stay ungated. Refresh-copied kid
# webapps are not an install path. Battle.net is refused, not gated.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_bin="$test_tmp/bin"
test_home="$test_tmp/home"
mkdir -p "$mock_bin" "$test_home/.local/share/applications"

adult_marker="$test_tmp/profile-default"
printf 'default\n' >"$adult_marker"
child_marker="$test_tmp/profile-child"
printf 'child\n' >"$child_marker"

sudo_log="$test_tmp/sudo.log"
prompt_log="$test_tmp/sudo.prompts"
ticket="$test_tmp/sudo.ticket"
: >"$sudo_log"
: >"$prompt_log"

cat >"$mock_bin/sudo" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_SUDO_LOG"
case "$1" in
  -v)
    if [[ ${OMARCHY_TEST_SUDO_V_STATUS:-0} != 0 ]]; then
      printf 'prompt\n' >>"$OMARCHY_TEST_SUDO_PROMPTS"
      exit "$OMARCHY_TEST_SUDO_V_STATUS"
    fi
    if [[ ! -f $OMARCHY_TEST_SUDO_TICKET ]]; then
      printf 'prompt\n' >>"$OMARCHY_TEST_SUDO_PROMPTS"
      : >"$OMARCHY_TEST_SUDO_TICKET"
    fi
    exit 0
    ;;
  -k)
    rm -f "$OMARCHY_TEST_SUDO_TICKET"
    exit 0
    ;;
  -n)
    [[ -f $OMARCHY_TEST_SUDO_TICKET ]] || exit 1
    exit 0
    ;;
esac
if [[ ! -f $OMARCHY_TEST_SUDO_TICKET ]]; then
  printf 'prompt\n' >>"$OMARCHY_TEST_SUDO_PROMPTS"
  : >"$OMARCHY_TEST_SUDO_TICKET"
fi
exit 0
SH

cat >"$mock_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash
exit "${OMARCHY_TEST_PKG_MISSING:-0}"
SH

cat >"$mock_bin/pacman" <<'SH'
#!/bin/bash
if [[ $1 == "-Q" || $1 == "-Slq" || $1 == "-Sii" ]]; then
  if [[ $1 == "-Slq" ]]; then
    printf 'example-pkg\n'
  fi
  exit 0
fi
printf '%s\n' "$*" >>"$OMARCHY_TEST_PACMAN_LOG"
exit 0
SH

cat >"$mock_bin/yay" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_YAY_LOG"
if [[ $1 == "-Slqa" ]]; then
  printf 'aur-example\n'
  exit 0
fi
if [[ $1 == "-S" ]]; then
  sudo pacman -U --noconfirm dep1.pkg
  sudo pacman -U --noconfirm dep2.pkg
  sudo pacman -U --noconfirm mock.pkg
fi
exit 0
SH

cat >"$mock_bin/fzf" <<'SH'
#!/bin/bash
if [[ -n ${OMARCHY_TEST_FZF_EMPTY:-} ]]; then
  exit 0
fi
cat
SH

cat >"$mock_bin/omarchy-show-done" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$mock_bin/gtk-update-icon-cache" <<'SH'
#!/bin/bash
exit 0
SH

chmod +x "$mock_bin"/*

export PATH="$mock_bin:$ROOT/bin:$PATH"
export HOME="$test_home"
export OMARCHY_PATH="$ROOT"
export OMARCHY_TEST_SUDO_LOG="$sudo_log"
export OMARCHY_TEST_SUDO_PROMPTS="$prompt_log"
export OMARCHY_TEST_SUDO_TICKET="$ticket"
export OMARCHY_TEST_PACMAN_LOG="$test_tmp/pacman.log"
export OMARCHY_TEST_YAY_LOG="$test_tmp/yay.log"
export OMARCHY_TEST_SUDO_V_STATUS=0
export OMARCHY_TEST_PKG_MISSING=0

reset_sudo() {
  : >"$sudo_log"
  : >"$prompt_log"
  rm -f "$ticket"
}

prompt_count() {
  wc -l <"$prompt_log"
}

source "$ROOT/install/helpers/child-install.sh"

reset_sudo
OMARCHY_PROFILE_FILE="$adult_marker" child_require_install
[[ ! -s $sudo_log ]] || fail "the default profile does not call sudo -v" "$(cat "$sudo_log")"
pass "the default profile does not ask sudo to install"

reset_sudo
OMARCHY_PROFILE_FILE="$child_marker" child_require_install
[[ $(<"$sudo_log") == "-v" ]] || fail "a child profile calls sudo -v" "$(cat "$sudo_log")"
[[ -f $ticket ]] || fail "sudo -v mints a ticket the rest of the install can reuse"
pass "a child profile asks sudo before installing"

reset_sudo
OMARCHY_TEST_SUDO_V_STATUS=1
if OMARCHY_PROFILE_FILE="$child_marker" child_require_install; then
  fail "a refused sudo -v fails the install gate"
fi
OMARCHY_TEST_SUDO_V_STATUS=0
pass "a refused sudo -v fails the install gate"

for hub in \
  omarchy-webapp-install \
  omarchy-tui-install \
  omarchy-install-gaming-geforce-now; do
  grep -Fq 'source "$OMARCHY_PATH/install/helpers/child-install.sh"' "$ROOT/bin/$hub" ||
    fail "$hub sources the child install helper from OMARCHY_PATH"
  grep -Fq child_require_install "$ROOT/bin/$hub" ||
    fail "$hub calls child_require_install"
  grep -Fq '${OMARCHY_PATH:-/usr/share/omarchy}' "$ROOT/bin/$hub" &&
    fail "$hub does not fall back to /usr/share/omarchy" || true
done
pass "user-scope install hubs source the child install helper"

grep -Fq child_require_install "$ROOT/bin/omarchy-install-gaming-battlenet" &&
  fail "Battle.net is refused on a child profile, not gated" || true
grep -Fq 'not available on a child install' "$ROOT/bin/omarchy-install-gaming-battlenet" ||
  fail "Battle.net names the child-install refusal"
pass "Battle.net is blocked on a child install"

for hub in omarchy-pkg-add omarchy-pkg-install omarchy-pkg-aur-add omarchy-pkg-aur-install; do
  grep -Fq child_require_install "$ROOT/bin/$hub" &&
    fail "$hub does not pre-check sudo -v" || true
  grep -Fq child-install.sh "$ROOT/bin/$hub" &&
    fail "$hub does not source the install helper" || true
done
pass "pkg and AUR installers skip the sudo -v pre-check"

grep -Fq child_require_install "$ROOT/bin/omarchy-refresh-applications" &&
  fail "refresh-applications is not an install path" || true
grep -Fq child-install.sh "$ROOT/bin/omarchy-refresh-applications" &&
  fail "refresh-applications does not source the install helper" || true
grep -Fq child_require_install "$ROOT/bin/omarchy-plugin-add" &&
  fail "plugin add stays ungated" || true
pass "refresh and plugins stay outside the install gate"

# Default profile still writes a webapp launcher without touching sudo.
reset_sudo
OMARCHY_PROFILE_FILE="$adult_marker" \
  omarchy-webapp-install Example https://example.com webapp >/dev/null
[[ -f $test_home/.local/share/applications/Example.desktop ]] ||
  fail "a default profile still installs a web app"
[[ ! -s $sudo_log ]] || fail "a default webapp install does not call sudo" "$(cat "$sudo_log")"
pass "a default profile still installs a web app without sudo"

# Child profile: refused sudo writes nothing.
rm -f "$test_home/.local/share/applications/Example.desktop"
reset_sudo
OMARCHY_TEST_SUDO_V_STATUS=1
if OMARCHY_PROFILE_FILE="$child_marker" \
  omarchy-webapp-install Blocked https://example.com webapp >/dev/null 2>"$test_tmp/webapp.err"; then
  fail "a child profile refuses a webapp install without sudo"
fi
OMARCHY_TEST_SUDO_V_STATUS=0
[[ ! -e $test_home/.local/share/applications/Blocked.desktop ]] ||
  fail "a refused child webapp install writes no desktop file"
grep -Fq 'parent password' "$test_tmp/webapp.err" ||
  fail "a child webapp install names the parent password" "$(cat "$test_tmp/webapp.err")"
pass "a child profile gates omarchy-webapp-install"

# Child profile: accepted sudo then writes the launcher and drops the ticket.
reset_sudo
OMARCHY_PROFILE_FILE="$child_marker" \
  omarchy-webapp-install Allowed https://example.com webapp >/dev/null 2>"$test_tmp/webapp-ok.err"
[[ -f $test_home/.local/share/applications/Allowed.desktop ]] ||
  fail "a child profile installs a web app after sudo -v"
[[ $(<"$sudo_log") == $'-v\n-k' ]] || fail "a child webapp install asks once then drops the ticket" "$(cat "$sudo_log")"
(( $(prompt_count) == 1 )) || fail "a child webapp install prompts once" "$(cat "$prompt_log")"
[[ ! -f $ticket ]] || fail "a finished child webapp install leaves no ticket"
pass "a child webapp install asks once, writes the launcher, and drops the ticket"

# TUI install is the same user-scope path.
reset_sudo
OMARCHY_TEST_SUDO_V_STATUS=1
if OMARCHY_PROFILE_FILE="$child_marker" \
  omarchy-tui-install BlockedTui "echo hi" tile terminal >/dev/null 2>"$test_tmp/tui.err"; then
  fail "a child profile refuses a TUI install without sudo"
fi
OMARCHY_TEST_SUDO_V_STATUS=0
[[ ! -e $test_home/.local/share/applications/BlockedTui.desktop ]] ||
  fail "a refused child TUI install writes no desktop file"
pass "a child profile gates omarchy-tui-install"

reset_sudo
OMARCHY_PROFILE_FILE="$child_marker" \
  omarchy-tui-install AllowedTui "echo hi" tile terminal >/dev/null
[[ -f $test_home/.local/share/applications/AllowedTui.desktop ]] ||
  fail "a child profile installs a TUI after sudo -v"
[[ $(<"$sudo_log") == $'-v\n-k' ]] || fail "a child TUI install asks once then drops the ticket" "$(cat "$sudo_log")"
pass "a child TUI install asks once, then writes the launcher"

# Battle.net refuses on a child profile without asking for a password.
reset_sudo
if OMARCHY_PROFILE_FILE="$child_marker" \
  omarchy-install-gaming-battlenet >/dev/null 2>"$test_tmp/battlenet.err"; then
  fail "Battle.net refuses on a child profile"
fi
grep -Fq 'not available on a child install' "$test_tmp/battlenet.err" ||
  fail "Battle.net names the child-install refusal" "$(cat "$test_tmp/battlenet.err")"
[[ ! -s $sudo_log ]] || fail "Battle.net does not ask for the parent password" "$(cat "$sudo_log")"
pass "Battle.net refuses on a child profile without prompting"

# pkg-add uses sudo pacman only. Child and default look the same: one sudo,
# and nothing when the package is already present.
reset_sudo
: >"$OMARCHY_TEST_PACMAN_LOG"
OMARCHY_PROFILE_FILE="$adult_marker" omarchy-pkg-add example-pkg
grep -qxF -- '-v' "$sudo_log" && fail "a default pkg-add does not call sudo -v" "$(cat "$sudo_log")"
[[ $(<"$sudo_log") == "pacman -S --noconfirm --needed example-pkg" ]] ||
  fail "a default pkg-add uses sudo pacman once" "$(cat "$sudo_log")"
pass "a default pkg-add uses sudo only for pacman"

reset_sudo
OMARCHY_PROFILE_FILE="$child_marker" omarchy-pkg-add example-pkg
grep -qxF -- '-v' "$sudo_log" && fail "a child pkg-add does not call sudo -v" "$(cat "$sudo_log")"
[[ $(<"$sudo_log") == "pacman -S --noconfirm --needed example-pkg" ]] ||
  fail "a child pkg-add asks once via sudo pacman" "$(cat "$sudo_log")"
(( $(prompt_count) == 1 )) || fail "a child pkg-add prompts once" "$(cat "$prompt_log")"
pass "a child pkg-add asks once via sudo pacman"

reset_sudo
: >"$OMARCHY_TEST_PACMAN_LOG"
OMARCHY_TEST_PKG_MISSING=1
OMARCHY_PROFILE_FILE="$child_marker" omarchy-pkg-add already-present
OMARCHY_TEST_PKG_MISSING=0
[[ ! -s $sudo_log ]] || fail "an already-present package does not call sudo" "$(cat "$sudo_log")"
[[ ! -s $OMARCHY_TEST_PACMAN_LOG ]] || fail "an already-present package does not call pacman"
pass "an already-present package asks for no password"

# AUR add: yay's nested sudos reuse one ticket.
reset_sudo
: >"$OMARCHY_TEST_YAY_LOG"
OMARCHY_PROFILE_FILE="$child_marker" omarchy-pkg-aur-add aur-example
grep -qxF -- '-v' "$sudo_log" && fail "a child AUR add does not call sudo -v" "$(cat "$sudo_log")"
[[ $(grep -c 'pacman -U --noconfirm' "$sudo_log") == 3 ]] ||
  fail "a child AUR add runs yay's nested sudo pacman calls" "$(cat "$sudo_log")"
(( $(prompt_count) == 1 )) || fail "yay's nested sudos reuse one ticket" "$(cat "$prompt_log")"
[[ -s $OMARCHY_TEST_YAY_LOG ]] || fail "a child AUR add runs yay"
pass "a child AUR add asks once via yay's sudo ticket"

reset_sudo
: >"$OMARCHY_TEST_YAY_LOG"
OMARCHY_TEST_PKG_MISSING=1
OMARCHY_PROFILE_FILE="$child_marker" omarchy-pkg-aur-add already-present
OMARCHY_TEST_PKG_MISSING=0
[[ ! -s $sudo_log ]] || fail "an already-present AUR package does not call sudo" "$(cat "$sudo_log")"
[[ ! -s $OMARCHY_TEST_YAY_LOG ]] || fail "an already-present AUR package does not start yay"
pass "an already-present AUR package asks for no password"

# Interactive pkg install: keepalive + sudo pacman is one prompt; child drops the ticket.
reset_sudo
printf 'example-pkg\n' | OMARCHY_PROFILE_FILE="$child_marker" omarchy-pkg-install >/dev/null
grep -qxF -- '-v' "$sudo_log" || fail "pkg-install uses keepalive sudo -v" "$(cat "$sudo_log")"
grep -Fq 'pacman -S --noconfirm' "$sudo_log" || fail "pkg-install still installs through sudo pacman" "$(cat "$sudo_log")"
grep -qxF -- '-k' "$sudo_log" || fail "pkg-install drops the ticket on a child profile" "$(cat "$sudo_log")"
(( $(prompt_count) == 1 )) || fail "pkg-install prompts once" "$(cat "$prompt_log")"
[[ ! -f $ticket ]] || fail "a finished child pkg-install leaves no ticket"
pass "pkg-install asks once, then drops the ticket on a child profile"

reset_sudo
OMARCHY_TEST_FZF_EMPTY=1 OMARCHY_PROFILE_FILE="$child_marker" omarchy-pkg-install >/dev/null
[[ ! -s $sudo_log ]] || fail "a canceled pkg-install asks nothing" "$(cat "$sudo_log")"
pass "a canceled pkg-install asks nothing"

# Interactive AUR install: keepalive covers yay's nested sudos and updatedb.
reset_sudo
: >"$OMARCHY_TEST_YAY_LOG"
printf 'aur-example\n' | OMARCHY_PROFILE_FILE="$child_marker" omarchy-pkg-aur-install >/dev/null
grep -qxF -- '-v' "$sudo_log" || fail "aur-install uses keepalive sudo -v" "$(cat "$sudo_log")"
[[ $(grep -c 'pacman -U --noconfirm' "$sudo_log") == 3 ]] ||
  fail "aur-install runs yay's nested sudo calls" "$(cat "$sudo_log")"
grep -Fq 'updatedb --prune-bind-mounts=no' "$sudo_log" ||
  fail "aur-install still refreshes updatedb" "$(cat "$sudo_log")"
grep -qxF -- '-k' "$sudo_log" || fail "aur-install drops the ticket on a child profile" "$(cat "$sudo_log")"
(( $(prompt_count) == 1 )) || fail "aur-install nested sudos reuse one ticket" "$(cat "$prompt_log")"
[[ ! -f $ticket ]] || fail "a finished child aur-install leaves no ticket"
pass "aur-install asks once for nested sudos, then drops the ticket"

# Refresh still copies the shipped kid webapps without asking sudo.
reset_sudo
for command in omarchy-cmd-present omarchy-mise-install omarchy-install-hermes-cli update-desktop-database; do
  printf '#!/bin/bash\nexit 0\n' >"$mock_bin/$command"
done
chmod +x "$mock_bin"/*
OMARCHY_PROFILE_FILE="$child_marker" omarchy-refresh-applications
[[ -f "$test_home/.local/share/applications/Khan Academy.desktop" ]] ||
  fail "refresh still copies Khan Academy on a child profile"
[[ ! -s $sudo_log ]] || fail "refresh does not ask sudo to copy kid webapps" "$(cat "$sudo_log")"
pass "refresh still copies child webapps without sudo"

grep -Fq 'sudo -v' "$ROOT/install/helpers/child-install.sh" ||
  fail "the install gate still authenticates with sudo -v"
grep -Fq child_drop_install_ticket "$ROOT/install/helpers/child-install.sh" ||
  fail "the helper exposes child_drop_install_ticket for the command's cleanup"
if grep -qE '^[[:space:]]*trap ' "$ROOT/install/helpers/child-install.sh"; then
  fail "the sourced install helper must not set an EXIT trap"
fi
for hub in omarchy-webapp-install omarchy-tui-install omarchy-install-gaming-geforce-now; do
  grep -Fq 'trap child_drop_install_ticket EXIT' "$ROOT/bin/$hub" ||
    fail "$hub drops the ticket from its own EXIT trap"
done
[[ ! -e $ROOT/migrations/1790417490.sh ]] || fail "the child sudo timeout migration is gone"
pass "the install gate asks once and drops the ticket"

# Sourced helper must not replace a caller's EXIT trap. sudo -k still runs
# from the command's own cleanup on both success and failure.
caller_partial=$test_tmp/caller-partial
reset_sudo
: >"$caller_partial"
(
  trap 'rm -f "$caller_partial" # caller-partial' EXIT
  source "$ROOT/install/helpers/child-install.sh"
  OMARCHY_PROFILE_FILE="$child_marker" child_require_install
  trap -p EXIT | grep -Fq caller-partial ||
    fail "child_require_install left the caller EXIT trap in place"
  if grep -qxF -- '-k' "$sudo_log"; then
    fail "the sourced helper does not drop the ticket itself" "$(cat "$sudo_log")"
  fi
)
[[ ! -f $caller_partial ]] || fail "the caller EXIT trap still runs after sourcing the install helper"
pass "sourcing the install helper keeps the caller EXIT trap"

reset_sudo
: >"$caller_partial"
if OMARCHY_PROFILE_FILE="$child_marker" \
  omarchy-webapp-install "Bad/Name" https://example.com webapp >/dev/null 2>"$test_tmp/webapp-fail.err"; then
  fail "a slash in the webapp name still fails after the gate"
fi
[[ $(<"$sudo_log") == $'-v\n-k' ]] ||
  fail "a failed child webapp install still drops the ticket" "$(cat "$sudo_log")"
[[ ! -f $ticket ]] || fail "a failed child webapp install leaves no ticket"
[[ ! -e $test_home/.local/share/applications/Bad/Name.desktop ]] ||
  fail "a failed child webapp install writes no desktop file"
pass "a failed child webapp install still drops the ticket"

reset_sudo
: >"$caller_partial"
(
  export OMARCHY_PROFILE_FILE="$child_marker"
  trap 'rm -f "$caller_partial"' EXIT
  source omarchy-sudo-keepalive
  [[ -f $ticket ]] || fail "keepalive mints a ticket"
  exit 0
)
[[ ! -f $caller_partial ]] || fail "keepalive chains the caller EXIT trap on success"
grep -qxF -- '-k' "$sudo_log" || fail "keepalive drops the ticket on success" "$(cat "$sudo_log")"
[[ ! -f $ticket ]] || fail "keepalive leaves no ticket on success"
pass "keepalive chains the caller EXIT trap and drops the ticket on success"

reset_sudo
: >"$caller_partial"
keepalive_fail_status=0
(
  export OMARCHY_PROFILE_FILE="$child_marker"
  trap 'rm -f "$caller_partial"' EXIT
  source omarchy-sudo-keepalive
  [[ -f $ticket ]] || exit 2
  exit 1
) || keepalive_fail_status=$?
(( keepalive_fail_status == 1 )) ||
  fail "the keepalive failure fixture exits 1" "status=$keepalive_fail_status"
[[ ! -f $caller_partial ]] || fail "keepalive chains the caller EXIT trap on failure"
grep -qxF -- '-k' "$sudo_log" || fail "keepalive drops the ticket on failure" "$(cat "$sudo_log")"
[[ ! -f $ticket ]] || fail "keepalive leaves no ticket on failure"
pass "keepalive chains the caller EXIT trap and drops the ticket on failure"

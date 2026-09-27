#!/bin/bash
#
# quattro's one-prompt update (e1614f2b), the child profile's Defaults rootpw
# parent password, and the child keepalive's sudo -k EXIT trap have to stay
# on separate paths. Update keeps its own session; installers use keepalive.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

update="$ROOT/bin/omarchy-update"
keepalive="$ROOT/bin/omarchy-sudo-keepalive"
parent="$ROOT/bin/omarchy-parent"

grep -Fq 'source omarchy-sudo-keepalive' "$update" &&
  fail "omarchy-update does not source the installer keepalive" || true
grep -Fq 'OMARCHY_UPDATE_SUDO_SESSION=1' "$update" ||
  fail "omarchy-update marks its own sudo session"
grep -Fq '/usr/bin/sudo /usr/bin/true' "$update" ||
  fail "omarchy-update authorizes once with sudo true"
grep -Fq 'omarchy_security_revoke_sudo_timestamp' "$update" ||
  fail "omarchy-update revokes the ticket when it finishes"
grep -Fq 'sudo -v' "$update" &&
  fail "omarchy-update does not pre-prompt with sudo -v" || true
pass "omarchy-update keeps a single authorize-and-revoke session"

grep -Fq 'Defaults rootpw' "$parent" ||
  fail "omarchy-parent apply writes Defaults rootpw"
grep -Fq 'passprompt="[sudo] parent password: "' "$parent" ||
  fail "omarchy-parent apply names the parent password on the sudo prompt"
pass "a child install makes sudo ask for the parent password"

grep -Fq 'omarchy-profile-child' "$keepalive" ||
  fail "omarchy-sudo-keepalive keys the ticket drop on the child profile"
grep -Fq 'sudo -k' "$keepalive" ||
  fail "omarchy-sudo-keepalive drops the ticket on child EXIT"
grep -Fq '_omarchy_prev_exit_body' "$keepalive" ||
  fail "omarchy-sudo-keepalive chains the caller's EXIT trap"
pass "installer keepalive drops the child ticket without replacing EXIT"

# Adult installers still source keepalive; that path must not become the
# update's. Update helpers that revoke on their own already honor the session.
stay_awake="$ROOT/bin/omarchy-update-stay-awake"
grep -Fq 'OMARCHY_UPDATE_SUDO_SESSION' "$stay_awake" ||
  fail "stay-awake leaves the update's authorization alone"
pass "update helpers do not steal the one-prompt ticket"

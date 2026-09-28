#!/bin/bash
#
# omarchy-parent sites is the kid's blocked-domain list: a root-owned file,
# a marked /etc/hosts sinkhole, and Chromium-family URLBlocklist. Independent
# of family DNS.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

sites="$ROOT/bin/omarchy-parent-sites"
helper="$ROOT/install/helpers/parent-sites.sh"
leaf="$ROOT/install/config/parent-sites.sh"

[[ -x $sites ]] || fail "omarchy-parent-sites is executable"
grep -q '^# omarchy:summary=' "$sites" || fail "omarchy-parent-sites carries command metadata"
grep -q '^# omarchy:requires-sudo=true' "$sites" || fail "omarchy-parent-sites is marked as requiring sudo"
help_output=$(bash "$sites" --help)
[[ $help_output == *"omarchy-parent sites"* && $help_output == *"block"* ]] ||
  fail "omarchy-parent-sites --help prints usage without elevating"
pass "omarchy-parent-sites answers --help before asking for a password"

grep -Fq 'run_logged "$OMARCHY_INSTALL/config/parent-sites.sh"' "$ROOT/install/config/all.sh" ||
  fail "the parent-sites leaf is wired into system setup"
grep -Fq 'OMARCHY_PARENT_BLOCK_YOUTUBE:-1' "$leaf" || fail "the install leaf defaults to blocking YouTube"
grep -Fq '== "child"' "$leaf" || fail "the install leaf only blocks sites on child installs"
grep -Fq 'omarchy_prompt_block_youtube' "$ROOT/install/provisioning/setup-form.sh" ||
  fail "the shared setup form offers the YouTube block choice for the ISO to call"
grep -Fq 'omacom/omarchy-iso#146' "$leaf" || fail "the install leaf names the ISO hook"
grep -Fq 'omarchy-parent-sites.json' "$helper" ||
  fail "Chromium policy uses a dedicated file that does not collide with color.json or dns.json"
pass "child installs default to blocking YouTube and leave a hook for omarchy-iso"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export OMARCHY_PATH="$ROOT"
export OMARCHY_PARENT_SITES_FILE="$test_tmp/parent-sites"
export OMARCHY_PARENT_SITES_HOSTS="$test_tmp/hosts"
export OMARCHY_PARENT_SITES_YOUTUBE="$ROOT/install/omarchy-parent-sites-youtube"
source "$ROOT/install/helpers/browser-policy.sh"
source "$helper"

[[ $(parent_sites_normalize "YouTube.com") == youtube.com ]] || fail "normalize lowercases and keeps the apex"
[[ $(parent_sites_normalize "https://www.youtube.com/watch?v=dQw4w9WgXcQ") == youtube.com ]] ||
  fail "normalize strips scheme, www, path and query from a YouTube URL"
[[ $(parent_sites_normalize "youtu.be") == youtube.com ]] || fail "youtu.be canonicalizes to youtube.com"
[[ $(parent_sites_normalize "WWW.TIKTOK.COM") == tiktok.com ]] || fail "normalize drops www for a generic domain"
if parent_sites_normalize "not a host" >/dev/null; then
  fail "normalize rejects a name with spaces"
fi
if parent_sites_normalize "localhost" >/dev/null; then
  fail "normalize rejects a single-label name"
fi
if parent_sites_normalize "127.0.0.1" >/dev/null; then
  fail "normalize rejects an IPv4 address"
fi
if parent_sites_normalize "javascript:alert(1)" >/dev/null; then
  fail "normalize rejects a non-http scheme"
fi
pass "domain names are normalized and invalid input is refused"

parent_sites_add youtube.com
hosts=$(parent_sites_all_hosts)
[[ $hosts == *youtube.com* && $hosts == *www.youtube.com* && $hosts == *m.youtube.com* ]] ||
  fail "blocking youtube.com includes www and m" "$hosts"
[[ $hosts == *youtu.be* && $hosts == *googlevideo.com* && $hosts == *ytimg.com* ]] ||
  fail "blocking youtube.com includes youtu.be and the video CDNs" "$hosts"
patterns=$(parent_sites_url_patterns)
[[ $patterns == *'*.youtube.com'* && $patterns == *'*.googlevideo.com'* ]] ||
  fail "URLBlocklist patterns cover youtube.com and googlevideo.com subdomains" "$patterns"
pass "YouTube expands to aliases and wildcard URLBlocklist patterns"

parent_sites_add tiktok.com
[[ $(parent_sites_list) == $'youtube.com\ntiktok.com' ]] || fail "the list keeps both domains" "$(parent_sites_list)"
parent_sites_remove youtube.com
[[ $(parent_sites_list) == tiktok.com ]] || fail "allow youtube.com leaves the other domain"
parent_sites_remove tiktok.com
[[ -z $(parent_sites_list) ]] || fail "allowing the last domain empties the list"
pass "block and allow edit the saved list"

printf '127.0.0.1 localhost\n' >"$PARENT_SITES_HOSTS"
parent_sites_add youtube.com
parent_sites_apply_hosts
grep -Fq '127.0.0.1 localhost' "$PARENT_SITES_HOSTS" || fail "hosts rewrite keeps the existing file"
grep -Fq "$PARENT_SITES_HOSTS_BEGIN" "$PARENT_SITES_HOSTS" || fail "hosts rewrite writes the marked section"
grep -Eq '^0\.0\.0\.0 youtube\.com$' "$PARENT_SITES_HOSTS" || fail "hosts sinkholes youtube.com to 0.0.0.0"
grep -Eq '^:: youtube\.com$' "$PARENT_SITES_HOSTS" || fail "hosts sinkholes youtube.com for IPv6"
grep -Eq '^0\.0\.0\.0 googlevideo\.com$' "$PARENT_SITES_HOSTS" || fail "hosts sinkholes googlevideo.com"
parent_sites_apply_hosts
(( $(grep -c "$PARENT_SITES_HOSTS_BEGIN" "$PARENT_SITES_HOSTS") == 1 )) ||
  fail "a second apply does not stack hosts sections"
parent_sites_remove youtube.com
parent_sites_apply_hosts
if grep -Fq "$PARENT_SITES_HOSTS_BEGIN" "$PARENT_SITES_HOSTS"; then
  fail "an empty list removes the hosts section"
fi
grep -Fq '127.0.0.1 localhost' "$PARENT_SITES_HOSTS" || fail "clearing the list keeps the rest of hosts"
pass "the hosts sinkhole is a marked section the kid cannot stack or keep after allow"

json=$(parent_sites_policy_json)
[[ $json == '{}' ]] || fail "an empty list writes no URLBlocklist" "$json"
parent_sites_add youtube.com
json=$(parent_sites_policy_json)
[[ $json == '{"URLBlocklist": '* ]] || fail "a non-empty list writes URLBlocklist JSON" "$json"
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$json" || fail "URLBlocklist JSON parses" "$json"
[[ $json == *'"*.googlevideo.com"'* && $json == *'"youtube.com"'* ]] ||
  fail "URLBlocklist names youtube.com and *.googlevideo.com" "$json"
pass "Chromium URLBlocklist JSON is valid and covers YouTube CDNs"

# Behavioral half: the real command as namespaced root, against scratch paths.
if ! unshare --user --map-root-user true 2>/dev/null; then
  pass "no unprivileged user namespace; skipping the omarchy-parent-sites command probes"
  exit 0
fi

stub_bin="$test_tmp/bin"
fx_dir="$test_tmp/firefox/distribution"
mkdir -p "$stub_bin" "$test_tmp/chromium/policies/managed" "$fx_dir"
cat >"$stub_bin/omarchy-profile-child" <<'SH'
#!/bin/bash
[[ ${STUB_PROFILE:-child} == child ]]
SH
cat >"$stub_bin/resolvectl" <<'SH'
#!/bin/bash
printf 'resolvectl %s\n' "$*" >>"${RESOLVE_CALLS:-/dev/null}"
SH
chmod +x "$stub_bin"/*

cat >"$fx_dir/policies.json" <<'JSON'
{
  "policies": {
    "Preferences": {
      "media.ffmpeg.vaapi.enabled": {
        "Value": true,
        "Status": "default"
      }
    }
  }
}
JSON

cat >"$test_tmp/run-as-root" <<'SH'
#!/bin/bash
set -euo pipefail
export OMARCHY_PATH="$ROOT"
export OMARCHY_PARENT_SITES_FILE="$SITES_FILE"
export OMARCHY_PARENT_SITES_HOSTS="$HOSTS_FILE"
export OMARCHY_PARENT_SITES_YOUTUBE="$ROOT/install/omarchy-parent-sites-youtube"
PATH="$STUB_BIN:$PATH"
source "$OMARCHY_PATH/install/helpers/browser-policy.sh"
BROWSER_POLICY_MANAGED_DIRS=("$POLICY_DIR")
BROWSER_POLICY_FIREFOX_DIRS=("$FIREFOX_DIR")
source "$OMARCHY_PATH/install/helpers/parent-sites.sh"
fail() { echo "Error: $1" >&2; exit 1; }
case "$1" in
  block) parent_sites_add "$(parent_sites_normalize "$2")"; parent_sites_apply ;;
  allow) parent_sites_remove "$(parent_sites_normalize "$2")"; parent_sites_apply ;;
  list) parent_sites_list ;;
esac
SH
chmod +x "$test_tmp/run-as-root"

run_root() {
  unshare --user --map-root-user env \
    ROOT="$ROOT" SITES_FILE="$test_tmp/parent-sites" HOSTS_FILE="$test_tmp/hosts" \
    POLICY_DIR="$test_tmp/chromium/policies/managed" FIREFOX_DIR="$fx_dir" \
    STUB_BIN="$stub_bin" \
    bash "$test_tmp/run-as-root" "$@"
}

printf '127.0.0.1 localhost\n' >"$test_tmp/hosts"
rm -f "$test_tmp/parent-sites"
run_root block youtube.com
grep -qx youtube.com "$test_tmp/parent-sites" || fail "block records youtube.com" "$(<"$test_tmp/parent-sites")"
grep -Eq '^0\.0\.0\.0 youtube\.com$' "$test_tmp/hosts" || fail "block writes the hosts sinkhole"
[[ -f $test_tmp/chromium/policies/managed/omarchy-parent-sites.json ]] ||
  fail "block writes Chromium URLBlocklist policy"
grep -F '*.googlevideo.com' "$test_tmp/chromium/policies/managed/omarchy-parent-sites.json" >/dev/null ||
  fail "Chromium policy wildcards googlevideo.com"
mode=$(stat -c %a "$test_tmp/parent-sites")
[[ $mode == 644 ]] || fail "the sites file is world-readable" "$mode"
python3 - "$fx_dir/policies.json" <<'PY' || fail "Firefox WebsiteFilter lists YouTube match patterns"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
block = data["policies"]["WebsiteFilter"]["Block"]
assert "media.ffmpeg.vaapi.enabled" in data["policies"]["Preferences"]
assert "*://youtube.com/*" in block
assert "*://*.googlevideo.com/*" in block
PY
run_root allow youtube.com
[[ -z $(grep -v '^#' "$test_tmp/parent-sites" | grep -v '^$' || true) ]] || fail "allow clears youtube.com"
[[ ! -e $test_tmp/chromium/policies/managed/omarchy-parent-sites.json ]] ||
  fail "allow removes the Chromium policy file"
if grep -Fq "$PARENT_SITES_HOSTS_BEGIN" "$test_tmp/hosts"; then
  fail "allow removes the hosts section"
fi
python3 - "$fx_dir/policies.json" <<'PY' || fail "an empty list drops WebsiteFilter and keeps VAAPI"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "WebsiteFilter" not in data["policies"]
assert "media.ffmpeg.vaapi.enabled" in data["policies"]["Preferences"]
PY
pass "block and allow apply hosts and browser policy as root"

if STUB_PROFILE=default PATH="$stub_bin:$PATH" OMARCHY_PATH="$ROOT" \
  unshare --user --map-root-user bash "$sites" block youtube.com >/dev/null 2>&1; then
  fail "sites refuses to run outside the child profile"
fi
pass "omarchy-parent sites refuses a non-child install"

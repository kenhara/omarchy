#!/bin/bash
#
# omarchy-parent sites is the kid's website list: a root-owned file of
# commented examples until a parent edits it, a marked /etc/hosts sinkhole in
# blocklist mode, and Chromium-family / Firefox policy. Independent of family DNS.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

sites="$ROOT/bin/omarchy-parent-sites"
helper="$ROOT/install/helpers/parent-sites.sh"
leaf="$ROOT/install/config/parent-sites.sh"
template="$ROOT/install/omarchy-parent-sites"

[[ -x $sites ]] || fail "omarchy-parent-sites is executable"
grep -q '^# omarchy:summary=' "$sites" || fail "omarchy-parent-sites carries command metadata"
grep -q '^# omarchy:requires-sudo=true' "$sites" || fail "omarchy-parent-sites is marked as requiring sudo"
help_output=$(bash "$sites" --help)
[[ $help_output == *"omarchy-parent sites"* && $help_output == *"block"* && $help_output == *"edit"* ]] ||
  fail "omarchy-parent-sites --help prints usage without elevating"
pass "omarchy-parent-sites answers --help before asking for a password"

grep -Fq 'run_logged "$OMARCHY_INSTALL/config/parent-sites.sh"' "$ROOT/install/config/all.sh" ||
  fail "the parent-sites leaf is wired into system setup"
grep -Fq 'omarchy-parent-sites seed' "$leaf" || fail "the install leaf only seeds the inert list"
if grep -q 'OMARCHY_PARENT_BLOCK_YOUTUBE' "$leaf" "$ROOT/install/provisioning/setup-form.sh" \
  "$ROOT/bin/omarchy-provision-owner" "$sites" "$helper"; then
  fail "YouTube is no longer blocked by default and the env var is gone"
fi
if grep -q 'omarchy_prompt_block_youtube' "$ROOT/install/provisioning/setup-form.sh" \
  "$ROOT/bin/omarchy-provision-owner"; then
  fail "the setup form no longer asks whether to block YouTube"
fi
grep -Fq '== "child"' "$leaf" || fail "the install leaf only seeds the list on child installs"
grep -Fq 'omarchy-parent-sites.json' "$helper" ||
  fail "Chromium policy uses a dedicated file that does not collide with color.json or dns.json"
grep -Fq 'show kids sites invitation' "$ROOT/bin/omarchy-provision-first-run" ||
  fail "first-run shows the kids sites invitation after welcome"
grep -Fq 'install/user/first-run/kids-sites.sh' "$ROOT/bin/omarchy-provision-first-run" ||
  fail "first-run runs kids-sites.sh"
pass "child installs seed an inert list and invite the parent on first login"

if grep -vE '^[[:space:]]*(#|$)' "$template" | grep -q .; then
  fail "the shipped website list is comments only" "$(<"$template")"
fi
grep -Fq '# youtube.com' "$template" || fail "the template comments youtube.com as a blocklist example"
grep -Fq '# tiktok.com' "$template" || fail "the template comments tiktok.com as a blocklist example"
grep -Fq '# mode: allowlist' "$template" || fail "the template comments allowlist mode"
grep -Fq '# khanacademy.org' "$template" || fail "the template comments khanacademy.org as an allowlist example"
grep -Fq '# scratch.mit.edu' "$template" || fail "the template comments scratch.mit.edu as an allowlist example"
grep -Fq '# wikipedia.org' "$template" || fail "the template comments wikipedia.org as an allowlist example"
pass "the shipped website list is inert commented examples"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
export OMARCHY_PATH="$ROOT"
export OMARCHY_PARENT_SITES_FILE="$test_tmp/parent-sites"
export OMARCHY_PARENT_SITES_HOSTS="$test_tmp/hosts"
export OMARCHY_PARENT_SITES_TEMPLATE="$template"
export OMARCHY_PARENT_SITES_YOUTUBE="$ROOT/install/omarchy-parent-sites-youtube"
source "$ROOT/install/helpers/browser-policy.sh"
source "$helper"

parent_sites_ensure_file
[[ -f $PARENT_SITES_FILE ]] || fail "seed copies the template"
[[ $(parent_sites_mode) == blocklist ]] || fail "commented examples default to blocklist mode"
[[ -z $(parent_sites_list) ]] || fail "commented examples list no active sites" "$(parent_sites_list)"
json=$(parent_sites_policy_json)
[[ $json == '{}' ]] || fail "an inert list writes no URLBlocklist" "$json"
printf '127.0.0.1 localhost\n' >"$PARENT_SITES_HOSTS"
parent_sites_apply_hosts
if grep -Fq "$PARENT_SITES_HOSTS_BEGIN" "$PARENT_SITES_HOSTS"; then
  fail "an inert list does not write a hosts section"
fi
grep -Fq '127.0.0.1 localhost' "$PARENT_SITES_HOSTS" || fail "seed apply keeps the rest of hosts"
pass "seeded list is inert until a parent uncomments a name"

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
grep -qx 'youtube.com' "$PARENT_SITES_FILE" || fail "block uncomments the youtube.com example"
grep -Fq '# tiktok.com' "$PARENT_SITES_FILE" || fail "block leaves other examples commented"
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
grep -Fq '# youtube.com' "$PARENT_SITES_FILE" || fail "allow comments youtube.com back out instead of deleting the example"
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

printf 'mode: allowlist\nkhanacademy.org\n' >"$PARENT_SITES_FILE"
[[ $(parent_sites_mode) == allowlist ]] || fail "an uncommented mode: allowlist switches mode"
[[ $(parent_sites_list) == khanacademy.org ]] || fail "allowlist lists the allowed names" "$(parent_sites_list)"
printf '127.0.0.1 localhost\n' >"$PARENT_SITES_HOSTS"
parent_sites_apply_hosts
if grep -Fq "$PARENT_SITES_HOSTS_BEGIN" "$PARENT_SITES_HOSTS"; then
  fail "allowlist mode does not write a hosts sinkhole"
fi
json=$(parent_sites_policy_json)
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$json" || fail "allowlist JSON parses" "$json"
[[ $json == '{"URLBlocklist": ["*"], "URLAllowlist": '* ]] ||
  fail "allowlist writes URLBlocklist * plus URLAllowlist" "$json"
[[ $json == *'"khanacademy.org"'* && $json == *'"*.khanacademy.org"'* ]] ||
  fail "allowlist names khanacademy.org" "$json"
[[ $json == *'"chrome://*"'* && $json == *'"about:*"'* ]] ||
  fail "allowlist keeps browser chrome URLs usable" "$json"
parent_sites_add scratch.mit.edu
[[ $(parent_sites_list) == $'khanacademy.org\nscratch.mit.edu' ]] ||
  fail "allowlist add appends a name" "$(parent_sites_list)"
parent_sites_remove khanacademy.org
[[ $(parent_sites_list) == scratch.mit.edu ]] || fail "allowlist remove drops a name"
pass "allowlist is browser-only and does not touch /etc/hosts"

# Behavioral half: the real apply path as namespaced root, against scratch paths.
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
cat >"$stub_bin/nvim" <<'SH'
#!/bin/bash
printf 'youtube.com\n' >>"$1"
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
export OMARCHY_PARENT_SITES_TEMPLATE="$ROOT/install/omarchy-parent-sites"
export OMARCHY_PARENT_SITES_YOUTUBE="$ROOT/install/omarchy-parent-sites-youtube"
PATH="$STUB_BIN:$PATH"
source "$OMARCHY_PATH/install/helpers/browser-policy.sh"
BROWSER_POLICY_MANAGED_DIRS=("$POLICY_DIR")
BROWSER_POLICY_FIREFOX_DIRS=("$FIREFOX_DIR")
source "$OMARCHY_PATH/install/helpers/parent-sites.sh"
fail() { echo "Error: $1" >&2; exit 1; }
case "$1" in
  seed) parent_sites_ensure_file ;;
  block) parent_sites_add "$(parent_sites_normalize "$2")"; parent_sites_apply ;;
  allow) parent_sites_remove "$(parent_sites_normalize "$2")"; parent_sites_apply ;;
  list) parent_sites_list ;;
  apply) parent_sites_apply ;;
  edit) parent_sites_ensure_file; "$(parent_sites_editor)" "$PARENT_SITES_FILE"; parent_sites_apply ;;
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
run_root seed
run_root apply
[[ -z $(parent_sites_list) ]] || fail "seed apply lists no sites"
[[ ! -e $test_tmp/chromium/policies/managed/omarchy-parent-sites.json ]] ||
  fail "seed apply writes no Chromium policy"
if grep -Fq "$PARENT_SITES_HOSTS_BEGIN" "$test_tmp/hosts"; then
  fail "seed apply writes no hosts section"
fi
python3 - "$fx_dir/policies.json" <<'PY' || fail "seed apply leaves Firefox without WebsiteFilter"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "WebsiteFilter" not in data["policies"]
assert "media.ffmpeg.vaapi.enabled" in data["policies"]["Preferences"]
PY
pass "seed apply is a no-op on an inert list"

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

printf 'mode: allowlist\nkhanacademy.org\n' >"$test_tmp/parent-sites"
run_root apply
if grep -Fq "$PARENT_SITES_HOSTS_BEGIN" "$test_tmp/hosts"; then
  fail "allowlist apply does not write a hosts section"
fi
python3 - "$test_tmp/chromium/policies/managed/omarchy-parent-sites.json" <<'PY' || fail "allowlist Chromium policy blocks all then allows listed names"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["URLBlocklist"] == ["*"]
assert "khanacademy.org" in data["URLAllowlist"]
assert "*.khanacademy.org" in data["URLAllowlist"]
assert "chrome://*" in data["URLAllowlist"]
PY
python3 - "$fx_dir/policies.json" <<'PY' || fail "allowlist Firefox WebsiteFilter uses <all_urls> plus Exceptions"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
filt = data["policies"]["WebsiteFilter"]
assert filt["Block"] == ["<all_urls>"]
assert "*://khanacademy.org/*" in filt["Exceptions"]
assert "media.ffmpeg.vaapi.enabled" in data["policies"]["Preferences"]
PY
pass "allowlist apply is browser policy only"

rm -f "$test_tmp/parent-sites"
printf '127.0.0.1 localhost\n' >"$test_tmp/hosts"
run_root edit
grep -qx youtube.com "$test_tmp/parent-sites" || fail "edit plus a save records youtube.com"
grep -Eq '^0\.0\.0\.0 youtube\.com$' "$test_tmp/hosts" || fail "edit apply writes the hosts sinkhole"
pass "sites edit opens the file and applies on save"

if STUB_PROFILE=default PATH="$stub_bin:$PATH" OMARCHY_PATH="$ROOT" \
  unshare --user --map-root-user bash "$sites" block youtube.com >/dev/null 2>&1; then
  fail "sites refuses to run outside the child profile"
fi
pass "omarchy-parent sites refuses a non-child install"

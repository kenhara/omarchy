# Shared by omarchy-parent-sites: the kid's blocked-domain list, the hosts
# sinkhole, and the Chromium-family URLBlocklist. Sourced after the caller has
# defined `fail`. Paths are overridable so the shell tests never touch the
# machine's /etc.

PARENT_SITES_FILE="${OMARCHY_PARENT_SITES_FILE:-/etc/omarchy/parent-sites}"
PARENT_SITES_HOSTS="${OMARCHY_PARENT_SITES_HOSTS:-/etc/hosts}"
PARENT_SITES_YOUTUBE="${OMARCHY_PARENT_SITES_YOUTUBE:-$OMARCHY_PATH/install/omarchy-parent-sites-youtube}"
PARENT_SITES_POLICY_NAME=omarchy-parent-sites.json
PARENT_SITES_HOSTS_BEGIN="# BEGIN omarchy-parent-sites"
PARENT_SITES_HOSTS_END="# END omarchy-parent-sites"

parent_sites_is_youtube() {
  case "$1" in
    youtube.com | youtu.be | youtube-nocookie.com) return 0 ;;
    *) return 1 ;;
  esac
}

# Strip a URL or hostname down to an apex domain, or fail. www. is dropped so
# blocking youtube.com and www.youtube.com is the same parent-facing name.
parent_sites_normalize() {
  local host="$1"

  host=${host,,}
  host=${host#"${host%%[![:space:]]*}"}
  host=${host%"${host##*[![:space:]]}"}
  [[ -n $host ]] || return 1

  host=${host#http://}
  host=${host#https://}
  host=${host%%/*}
  host=${host%%\?*}
  host=${host%%#*}
  host=${host%%:*}
  host=${host%.}
  host=${host#www.}
  [[ -n $host ]] || return 1

  if [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || $host == *:* ]]; then
    return 1
  fi
  [[ $host =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || return 1
  (( ${#host} < 254 )) || return 1

  if parent_sites_is_youtube "$host"; then
    host=youtube.com
  fi
  printf '%s\n' "$host"
}

parent_sites_read_lines() {
  local file="$1" line
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line || $line == \#* ]] && continue
    printf '%s\n' "$line"
  done <"$file"
}

parent_sites_list() {
  parent_sites_read_lines "$PARENT_SITES_FILE"
}

parent_sites_has() {
  local domain="$1" listed
  while IFS= read -r listed || [[ -n $listed ]]; do
    [[ $listed == "$domain" ]] && return 0
  done < <(parent_sites_list)
  return 1
}

parent_sites_write_list() {
  local directory stage domain
  directory=$(dirname "$PARENT_SITES_FILE") || return
  mkdir -p "$directory" || return
  stage=$(mktemp "$directory/.${PARENT_SITES_FILE##*/}.XXXXXX") || return
  cat >"$stage" <<'CONF'
# Omarchy kids mode: domains the kid account must not open.
# sudo omarchy-parent sites block|allow edits this file; a hand edit takes
# effect at the next `sudo omarchy-parent sites apply`.
CONF
  for domain in "$@"; do
    printf '%s\n' "$domain" >>"$stage" || return
  done
  chmod 644 "$stage" || return
  mv -f -- "$stage" "$PARENT_SITES_FILE"
}

parent_sites_add() {
  local domain="$1" listed=() current
  while IFS= read -r current || [[ -n $current ]]; do
    listed+=("$current")
  done < <(parent_sites_list)
  for current in "${listed[@]+"${listed[@]}"}"; do
    [[ $current == "$domain" ]] && return 0
  done
  listed+=("$domain")
  parent_sites_write_list "${listed[@]}"
}

parent_sites_remove() {
  local domain="$1" kept=() current
  while IFS= read -r current || [[ -n $current ]]; do
    [[ $current == "$domain" ]] && continue
    kept+=("$current")
  done < <(parent_sites_list)
  if (( ${#kept[@]} )); then
    parent_sites_write_list "${kept[@]}"
  else
    parent_sites_write_list
  fi
}

# Hostnames to sinkhole for one parent-facing domain: the name, www., and
# the YouTube alias set when that is the domain.
parent_sites_hosts_for() {
  local domain="$1" alias
  printf '%s\n' "$domain"
  printf 'www.%s\n' "$domain"
  parent_sites_is_youtube "$domain" || return 0
  [[ -f $PARENT_SITES_YOUTUBE ]] || return 0
  while IFS= read -r alias || [[ -n $alias ]]; do
    printf '%s\n' "$alias"
    [[ $alias == www.* ]] || printf 'www.%s\n' "$alias"
  done < <(parent_sites_read_lines "$PARENT_SITES_YOUTUBE")
}

parent_sites_all_hosts() {
  local domain
  while IFS= read -r domain || [[ -n $domain ]]; do
    parent_sites_hosts_for "$domain"
  done < <(parent_sites_list) | awk 'NF && !seen[$0]++'
}

# URLBlocklist patterns: the apex and *.apex so www/m/music and the YouTube
# CDNs (r*.googlevideo.com) are covered in Chromium-family browsers even when
# /etc/hosts cannot list every subdomain.
parent_sites_url_patterns() {
  local host
  while IFS= read -r host || [[ -n $host ]]; do
    printf '%s\n' "$host"
    printf '*.%s\n' "$host"
  done < <(parent_sites_all_hosts) | awk 'NF && !seen[$0]++'
}

parent_sites_json_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    if (( first )); then
      first=0
    else
      printf ', '
    fi
    printf '"%s"' "$item"
  done
  printf ']'
}

parent_sites_policy_json() {
  local patterns=() pattern
  while IFS= read -r pattern || [[ -n $pattern ]]; do
    patterns+=("$pattern")
  done < <(parent_sites_url_patterns)
  if (( ${#patterns[@]} == 0 )); then
    printf '%s\n' '{}'
    return
  fi
  printf '{"URLBlocklist": %s}\n' "$(parent_sites_json_array "${patterns[@]}")"
}

parent_sites_install_policy_file() {
  local dest="$1" content="$2" tmp
  tmp=$(mktemp) || return 1
  printf '%s' "$content" >"$tmp" || { rm -f "$tmp"; return 1; }
  [[ $content == *$'\n' ]] || printf '\n' >>"$tmp" || { rm -f "$tmp"; return 1; }
  if [[ -L $dest || -d $dest ]]; then
    rm -rf -- "$dest" || { rm -f "$tmp"; return 1; }
  fi
  if install -m 0644 -o root -g root -T "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

parent_sites_apply_chromium() {
  local dir dest json status=0
  json=$(parent_sites_policy_json)
  for dir in "${BROWSER_POLICY_MANAGED_DIRS[@]}"; do
    [[ -d $dir && ! -L $dir ]] || continue
    dest="$dir/$PARENT_SITES_POLICY_NAME"
    if [[ $json == '{}' ]]; then
      rm -rf -- "$dest" || status=1
      continue
    fi
    parent_sites_install_policy_file "$dest" "$json" || status=1
  done
  return "$status"
}

# Firefox has a single policies.json. Merge WebsiteFilter so VAAPI (and later
# family-DNS DoH pins) survive. python3 is the JSON writer.
parent_sites_firefox_merge() {
  local file="$1"
  local tmp patterns=()

  [[ -f $file && ! -L $file ]] || return 0
  command -v python3 >/dev/null || return 0

  local pattern
  while IFS= read -r pattern || [[ -n $pattern ]]; do
    patterns+=("*://$pattern/*" "*://*.$pattern/*")
  done < <(parent_sites_all_hosts)

  tmp=$(mktemp) || return 1
  if ! PARENT_SITES_FIREFOX_PATTERNS=$(printf '%s\n' "${patterns[@]+"${patterns[@]}"}") python3 - "$file" "$tmp" <<'PY'
import json
import os
import sys

src, dest = sys.argv[1], sys.argv[2]
raw = os.environ.get("PARENT_SITES_FIREFOX_PATTERNS", "")
patterns = [line for line in raw.splitlines() if line]
try:
    with open(src, encoding="utf-8") as fh:
        data = json.load(fh)
except json.JSONDecodeError:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
policies = data.setdefault("policies", {})
if not isinstance(policies, dict):
    sys.exit(1)
if patterns:
    policies["WebsiteFilter"] = {"Block": patterns, "Exceptions": []}
else:
    policies.pop("WebsiteFilter", None)
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  then
    rm -f "$tmp"
    return 1
  fi
  if install -m 644 -o root -g root -T "$tmp" "$file"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

parent_sites_apply_firefox() {
  local dir status=0
  for dir in "${BROWSER_POLICY_FIREFOX_DIRS[@]}"; do
    parent_sites_firefox_merge "$dir/policies.json" || status=1
  done
  return "$status"
}

parent_sites_hosts_without_section() {
  local file="$1" line in_section=0
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$PARENT_SITES_HOSTS_BEGIN" ]]; then
      in_section=1
      continue
    fi
    if [[ $line == "$PARENT_SITES_HOSTS_END" ]]; then
      in_section=0
      continue
    fi
    (( in_section )) && continue
    printf '%s\n' "$line"
  done <"$file"
}

parent_sites_apply_hosts() {
  local directory stage host rest
  directory=$(dirname "$PARENT_SITES_HOSTS") || return
  mkdir -p "$directory" || return
  stage=$(mktemp "$directory/.${PARENT_SITES_HOSTS##*/}.XXXXXX") || return
  rest=$(parent_sites_hosts_without_section "$PARENT_SITES_HOSTS")
  if [[ -n $rest ]]; then
    printf '%s\n' "$rest" >"$stage" || return
  else
    : >"$stage" || return
  fi
  if parent_sites_list | grep -q .; then
    [[ -s $stage ]] && printf '\n' >>"$stage"
    printf '%s\n' "$PARENT_SITES_HOSTS_BEGIN" >>"$stage"
    while IFS= read -r host || [[ -n $host ]]; do
      printf '0.0.0.0 %s\n:: %s\n' "$host" "$host" >>"$stage"
    done < <(parent_sites_all_hosts)
    printf '%s\n' "$PARENT_SITES_HOSTS_END" >>"$stage"
  fi
  chmod 644 "$stage" || return
  mv -f -- "$stage" "$PARENT_SITES_HOSTS"
}

parent_sites_flush_resolver() {
  command -v resolvectl >/dev/null || return 0
  resolvectl flush-caches >/dev/null 2>&1 || true
}

parent_sites_apply() {
  parent_sites_apply_hosts || fail "could not update $PARENT_SITES_HOSTS"
  parent_sites_apply_chromium || fail "could not write Chromium URLBlocklist policy"
  parent_sites_apply_firefox || fail "could not merge Firefox WebsiteFilter"
  parent_sites_flush_resolver
}

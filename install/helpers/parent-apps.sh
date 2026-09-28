# Shared by omarchy-parent-apps and omarchy-refresh-applications. The show
# and hide override files are root-owned and world-readable so a refresh
# running as the kid can honour them without sudo. Sourced after the caller
# has defined `fail` when it writes; refresh only reads.

PARENT_APPS_SHOW="${OMARCHY_PARENT_APPS_SHOW:-/etc/omarchy/parent-apps-show}"
PARENT_APPS_HIDE="${OMARCHY_PARENT_APPS_HIDE:-/etc/omarchy/parent-apps-hide}"
PARENT_APPS_SHIPPED="${OMARCHY_PARENT_APPS_SHIPPED:-$OMARCHY_PATH/install/omarchy-child-hidden-applications}"

parent_apps_read() {
  local file="$1" line
  [[ -f $file ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line || $line == \#* ]] && continue
    printf '%s\n' "$line"
  done <"$file"
}

# Launcher names are .desktop basenames without the suffix: letters, digits,
# spaces, and a short list of punctuation used by shipped names (Google Contacts).
parent_apps_normalize() {
  local name="$1" valid='^[A-Za-z0-9][A-Za-z0-9 ._+-]*$'
  name=${name#"${name%%[![:space:]]*}"}
  name=${name%"${name##*[![:space:]]}"}
  [[ -n $name ]] || return 1
  [[ $name != *..* && $name != */* && $name != *\\* ]] || return 1
  [[ $name != *.desktop ]] || return 1
  [[ $name =~ $valid ]] || return 1
  printf '%s\n' "$name"
}

parent_apps_has() {
  local needle="$1" file="$2" line
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == "$needle" ]] && return 0
  done < <(parent_apps_read "$file")
  return 1
}

parent_apps_write() {
  local file="$1"
  shift
  local directory stage name
  directory=$(dirname "$file") || return
  mkdir -p "$directory" || return
  stage=$(mktemp "$directory/.${file##*/}.XXXXXX") || return
  cat >"$stage" <<'CONF'
# Omarchy kids mode: parent overrides for child launchers.
# sudo omarchy-parent apps show|hide edits this file.
CONF
  for name in "$@"; do
    printf '%s\n' "$name" >>"$stage" || return
  done
  chmod 644 "$stage" || return
  mv -f -- "$stage" "$file"
}

parent_apps_add() {
  local file="$1" name="$2" listed=() current
  while IFS= read -r current || [[ -n $current ]]; do
    listed+=("$current")
  done < <(parent_apps_read "$file")
  for current in "${listed[@]+"${listed[@]}"}"; do
    [[ $current == "$name" ]] && return 0
  done
  listed+=("$name")
  parent_apps_write "$file" "${listed[@]}"
}

parent_apps_remove() {
  local file="$1" name="$2" kept=() current
  while IFS= read -r current || [[ -n $current ]]; do
    [[ $current == "$name" ]] && continue
    kept+=("$current")
  done < <(parent_apps_read "$file")
  parent_apps_write "$file" "${kept[@]+"${kept[@]}"}"
}

# Effective hide set: shipped list plus parent hide, minus parent show.
parent_apps_should_hide() {
  local name="$1"
  parent_apps_has "$name" "$PARENT_APPS_SHOW" && return 1
  parent_apps_has "$name" "$PARENT_APPS_SHIPPED" && return 0
  parent_apps_has "$name" "$PARENT_APPS_HIDE" && return 0
  return 1
}

parent_apps_refresh_home() {
  local home="$1" name
  while IFS= read -r name || [[ -n $name ]]; do
    parent_apps_should_hide "$name" || continue
    rm -f "$home/.local/share/applications/${name}.desktop"
  done < <(
    parent_apps_read "$PARENT_APPS_SHIPPED"
    parent_apps_read "$PARENT_APPS_HIDE"
  )
}

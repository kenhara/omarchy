# Shared by omarchy-plugin-add, omarchy-plugin-enable, and omarchy-plugin-clone.
# On a child install, recording a third-party plugin in the parent-approved
# list requires sudo (parent password under Defaults rootpw). The list lives
# at /etc/omarchy/plugins-parent-approved (root-owned, world-readable).
# The shell scan skips unlisted third-party ids on child installs.
#
# These paths are hardcoded. Tests may reassign the variables after sourcing.
# Session environment (uwsm, Hyprland, OMARCHY_PLUGIN_*, OMARCHY_PROFILE_FILE)
# does not relocate the list or disable the child scan.

PLUGIN_PARENT_APPROVED_FILE="/etc/omarchy/plugins-parent-approved"
PLUGIN_CHILD_PROFILE_FILE="/etc/omarchy/profile"

plugin_parent_gate_fail() {
  echo "$1: $2" >&2
  exit 1
}

plugin_is_first_party() {
  [[ $1 == omarchy.* ]]
}

plugin_is_parent_approved() {
  local id="$1"
  [[ -f $PLUGIN_PARENT_APPROVED_FILE ]] && grep -qxF "$id" "$PLUGIN_PARENT_APPROVED_FILE"
}

register_parent_approved_plugin() {
  local id="$1"
  local rc=0
  omarchy-profile-child || return 0
  plugin_is_first_party "$id" && return 0
  plugin_is_parent_approved "$id" && return 0
  [[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
    plugin_parent_gate_fail register "invalid plugin id"
  echo "Parent approval needed to add plugin '$id'."
  # Sourced: never set an EXIT trap here, or the caller's cleanup is replaced.
  sudo omarchy-plugin-approve "$id" || rc=$?
  sudo -k
  if (( rc != 0 )); then
    plugin_parent_gate_fail register "could not record parent approval for '$id'"
  fi
}

# Scan-only child check. Reads the install marker directly so a kid-set
# OMARCHY_PROFILE_FILE cannot disable the filter. Tests reassign
# PLUGIN_CHILD_PROFILE_FILE after sourcing.
plugin_scan_child_profile_active() {
  [[ -f $PLUGIN_CHILD_PROFILE_FILE ]] || return 1
  [[ $(<"$PLUGIN_CHILD_PROFILE_FILE") == child ]]
}

# Used by the shell plugin scan, the catalog, and by tests. Prints manifest paths to emit.
scan_thirdparty_plugin_manifests() {
  local plugins_dir="${1:?}"
  local sub id
  [[ -d $plugins_dir ]] || return 0
  for sub in "$plugins_dir"/*/; do
    sub="${sub%/}"
    [[ -f "$sub/manifest.json" ]] || continue
    if plugin_scan_child_profile_active; then
      id=$(jq -r '.id // empty' "$sub/manifest.json" 2>/dev/null) || continue
      [[ -n $id ]] || continue
      [[ ${sub##*/} == "$id" ]] || continue
      plugin_is_parent_approved "$id" || continue
    fi
    printf '%s\n' "$sub/manifest.json"
  done
}

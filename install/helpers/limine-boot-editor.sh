# Shared by omarchy-parent, omarchy-refresh-limine, and the post-save hook
# limine-entry-tool runs. Child installs turn Limine's boot-menu editor off so
# a kid cannot press E, add init=/bin/bash, remount the disk, and reset root.
# Regular installs never source this on their own; the shipped template is
# unchanged.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/as-root.sh"

LIMINE_CONF="${OMARCHY_LIMINE_CONF:-/boot/limine.conf}"
LIMINE_EDITOR_HOOK="${OMARCHY_LIMINE_EDITOR_HOOK:-/etc/boot/hooks/post.d/80-omarchy-child-boot-editor}"

# Set editor_enabled in the live Limine config. Missing files are a no-op so
# apply can run in the install chroot before the ESP is mounted, and tests can
# skip a real /boot. yes|no only; anything else is a caller bug.
set_limine_boot_editor() {
  local want="$1"
  local conf="${OMARCHY_LIMINE_CONF:-$LIMINE_CONF}"

  case "$want" in
    yes|no) ;;
    *) return 1 ;;
  esac

  as_root test -f "$conf" || return 0

  if as_root grep -Eq "^[[:space:]]*editor_enabled[[:space:]]*:[[:space:]]*$want[[:space:]]*$" "$conf"; then
    return 0
  fi

  if as_root grep -Eq '^[[:space:]]*editor_enabled[[:space:]]*:' "$conf"; then
    as_root sed -i -E "s/^[[:space:]]*editor_enabled[[:space:]]*:.*/editor_enabled: $want/" "$conf"
  elif as_root grep -Eq '^[[:space:]]*hash_mismatch_panic[[:space:]]*:' "$conf"; then
    as_root sed -i -E "/^[[:space:]]*hash_mismatch_panic[[:space:]]*:/a editor_enabled: $want" "$conf"
  else
    printf 'editor_enabled: %s\n' "$want" | as_root tee -a "$conf" >/dev/null
  fi
}

# limine-entry-tool's wrapper runs /etc/boot/hooks/post.d/* after it rewrites
# $ESP_PATH/limine.conf (limine-update, limine-mkinitcpio, limine-snapper-sync).
# The hook re-applies editor_enabled: no so a kernel update cannot restore E.
install_limine_boot_editor_hook() {
  local target="${OMARCHY_LIMINE_EDITOR_HOOK:-$LIMINE_EDITOR_HOOK}"
  local stage

  stage=$(mktemp)
  cat >"$stage" <<'HOOK'
#!/bin/bash
# Omarchy kids mode: keep Limine's boot-menu editor off after limine-entry-tool
# rewrites /boot/limine.conf. Written by omarchy-parent apply.
profile="${OMARCHY_PROFILE_FILE:-/etc/omarchy/profile}"
[[ -f $profile && $(<"$profile") == "child" ]] || exit 0
OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
[[ -f $OMARCHY_PATH/install/helpers/limine-boot-editor.sh ]] || exit 0
# shellcheck disable=SC1091
source "$OMARCHY_PATH/install/helpers/limine-boot-editor.sh"
set_limine_boot_editor no
HOOK
  as_root install -Dm755 "$stage" "$target"
  rm -f "$stage"
}

remove_limine_boot_editor_hook() {
  local target="${OMARCHY_LIMINE_EDITOR_HOOK:-$LIMINE_EDITOR_HOOK}"
  as_root rm -f "$target"
}

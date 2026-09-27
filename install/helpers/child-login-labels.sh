# Child-install login and lock labels: one account, two passwords. Written when
# omarchy-apply-lock or first-boot configure_login runs on a child profile.

CHILD_LOGIN_CONF="${OMARCHY_CHILD_LOGIN_CONF:-/etc/omarchy/child-login.conf}"
SDDM_THEME_CONF_USER="${OMARCHY_SDDM_THEME_CONF_USER:-/usr/share/sddm/themes/omarchy/theme.conf.user}"

omarchy_child_login_display_name() {
  local user=$1
  local gecos

  gecos=$(getent passwd "$user" 2>/dev/null | cut -d: -f5 | cut -d, -f1)
  if [[ -n $gecos ]]; then
    printf '%s\n' "$gecos"
  else
    printf '%s\n' "$user"
  fi
}

omarchy_child_login_password_hint() {
  local display_name=$1

  printf "%s's password or a parent password\n" "$display_name"
}

omarchy_apply_child_login_labels() {
  local user=${1:-${OMARCHY_INSTALL_USER:-}}
  local display_name hint

  if ! omarchy-profile-child; then
    omarchy_remove_child_login_labels
    return 0
  fi

  if [[ -z $user ]]; then
    return 0
  fi

  display_name=$(omarchy_child_login_display_name "$user")
  hint=$(omarchy_child_login_password_hint "$display_name")

  install -Dm644 /dev/null "$CHILD_LOGIN_CONF"
  printf 'display_name=%s\npassword_hint=%s\n' "$display_name" "$hint" >"$CHILD_LOGIN_CONF"

  install -Dm644 /dev/null "$SDDM_THEME_CONF_USER"
  printf '[General]\naccountDisplayName=%s\npasswordHint=%s\n' "$display_name" "$hint" >"$SDDM_THEME_CONF_USER"
}

omarchy_remove_child_login_labels() {
  rm -f "$CHILD_LOGIN_CONF" "$SDDM_THEME_CONF_USER"
}

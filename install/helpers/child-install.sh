# On a child profile, user-scope installers ask for the parent password, then drop the sudo ticket when they finish.

child_require_install() {
  if ! omarchy-profile-child; then
    return 0
  fi
  if (( EUID == 0 )); then
    return 0
  fi
  echo "Installing software on a child profile asks for the parent password." >&2
  sudo -v || return 1
  trap 'sudo -k' EXIT
}

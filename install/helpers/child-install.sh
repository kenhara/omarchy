# On a child profile, user-scope installers ask for the parent password. Callers drop the ticket from their own cleanup; this helper never sets EXIT.

child_require_install() {
  if ! omarchy-profile-child; then
    return 0
  fi
  if (( EUID == 0 )); then
    return 0
  fi
  echo "Installing software on a child profile asks for the parent password." >&2
  sudo -v || return 1
}

child_drop_install_ticket() {
  omarchy-profile-child || return 0
  if (( EUID == 0 )); then
    return 0
  fi
  sudo -k
}

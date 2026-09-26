echo "Turn on Family DNS for existing child installs"

omarchy-profile-child || exit 0

if [[ -f /etc/omarchy/parent.conf ]] && grep -q '^[[:space:]]*dns[[:space:]]*=' /etc/omarchy/parent.conf; then
  exit 0
fi

sudo omarchy-parent-dns on

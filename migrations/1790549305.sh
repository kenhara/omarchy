echo "Apply the family DNS egress filter and pin browser DoH on child installs"

source "$OMARCHY_PATH/install/helpers/dns.sh"

dns_is_child || exit 0
dns_locked || exit 0

"$OMARCHY_PATH/bin/omarchy-parent-dns" apply

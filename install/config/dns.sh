# A child install turns family DNS on by default: Cloudflare 1.1.1.1 for
# Families (malware + adult) over strict DNS-over-TLS, browser DoH off, and
# the kid's DNS picker locked. Deferred child installs have the profile
# marker already, so this leaf can write the resolver before a user exists.
if [[ ${OMARCHY_INSTALL_PROFILE:-default} == "child" ]]; then
  omarchy-parent-dns on
fi

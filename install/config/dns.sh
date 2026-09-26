# Child installs default to Cloudflare Families (malware + adult) over strict
# DNS-over-TLS. A deferred child has no user yet; first-boot provisioning
# makes the same call once omarchy-parent apply has run.
if [[ ${OMARCHY_INSTALL_PROFILE:-default} == "child" ]]; then
  omarchy-parent-dns on
fi

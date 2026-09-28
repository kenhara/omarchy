# Child installs get an inert website list (commented examples only). The
# parent is invited to edit it from a first-run notification; nothing is
# blocked until they uncomment names or run `omarchy-parent sites block`.
if [[ ${OMARCHY_INSTALL_PROFILE:-default} == "child" ]]; then
  omarchy-parent-sites seed
fi

# Child installs block YouTube unless the ISO asked the parent not to.
# Peter's omarchy-iso "Who is this computer for?" step (omacom/omarchy-iso#146)
# can call omarchy_prompt_block_youtube from setup-form.sh and export
# OMARCHY_PARENT_BLOCK_YOUTUBE=0 when the parent chose Allow YouTube. This leaf
# does not edit the ISO; a missing variable means the default, which is on.
# Regular (non-child) installs skip it.
if [[ ${OMARCHY_INSTALL_PROFILE:-default} == "child" && ${OMARCHY_PARENT_BLOCK_YOUTUBE:-1} == 1 ]]; then
  omarchy-parent-sites block youtube.com
fi

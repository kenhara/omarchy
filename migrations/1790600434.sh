echo "Disable the Limine boot-menu editor on child installs"

# A kid who can press E at the Limine menu can append init=/bin/bash, remount
# the disk, and reset root. Child installs installed before this repair still
# have the editor on; turn it off and install the post-save hook so the next
# limine-entry-tool run cannot restore it. Regular installs are left alone.

omarchy-profile-child || exit 0

source "$OMARCHY_PATH/install/helpers/limine-boot-editor.sh"
set_limine_boot_editor no
install_limine_boot_editor_hook

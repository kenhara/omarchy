#!/bin/bash

set -e

if omarchy-profile-child && omarchy-done ensure kids-sites-invitation; then
  omarchy-notification-send -u critical -g 󰖟 "Set up website list" \
    "Choose a blocklist or allowlist." \
    --exec omarchy-launch-floating-terminal-with-presentation omarchy-parent sites edit
fi

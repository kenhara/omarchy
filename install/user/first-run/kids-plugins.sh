#!/bin/bash

set -e

if omarchy-profile-child && omarchy-done ensure kids-plugins-invitation; then
  omarchy-notification-send -u critical -g 󰐱 "Explore Kids Plugins" \
    "Pick one and ask a parent to add it." \
    --exec omarchy-launch-webapp 'https://plugins.omarchy.org/?category=Kids'
fi

#!/bin/bash

set -euo pipefail

# The Kids collection ships as first-party themes. quattro's palette is semantic
# (background/foreground, no cursor token); a leftover Omarchy 4 authoring key
# fails test/cli and, more importantly, an upgrade that replaces
# /usr/share/omarchy/themes drops any theme that was only in the old package.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

kids_themes=(
  bubblegum
  cozy-night
  dino-dawn
  far-horizon
  festival-loom
  fossil-field-notes
  kinetic-zine
  lantern-menagerie
  night-transit
  paper-harbor
  pocket-arcade
  signal-garden
  small-wonders
  tidepool-workshop
  weather-parade
)

required_keys=(
  mode
  accent
  selection
  muted
  background
  dark_background
  darker_background
  lighter_background
  foreground
  dark_foreground
  light_foreground
  bright_foreground
  red
  yellow
  orange
  green
  cyan
  blue
  magenta
  brown
)

forbidden_keys=(
  cursor
  bg
  fg
  dark_bg
  darker_bg
  lighter_bg
  dark_fg
  light_fg
  bright_fg
  selection_foreground
  selection_background
  active_border_color
  active_tab_background
)

key_line() {
  awk -F'=' -v key="$2" '
    {
      k = $1
      gsub(/[[:space:]]/, "", k)
      if (k == key) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

for theme in "${kids_themes[@]}"; do
  dir="$ROOT/themes/$theme"
  [[ -d $dir ]] || fail "kids theme $theme is present under themes/"
  [[ -f $dir/colors.toml ]] || fail "kids theme $theme ships colors.toml"

  for key in "${required_keys[@]}"; do
    key_line "$dir/colors.toml" "$key" || fail "kids theme $theme defines canonical key $key"
  done

  for key in "${forbidden_keys[@]}"; do
    if key_line "$dir/colors.toml" "$key"; then
      fail "kids theme $theme omits retired palette key $key"
    fi
  done

  for n in $(seq 0 15); do
    if key_line "$dir/colors.toml" "color$n"; then
      fail "kids theme $theme omits ANSI color$n authoring key"
    fi
  done
done

pass "kids themes ship the current quattro palette keys"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# Render templates from each palette without copying wallpapers.
for theme in "${kids_themes[@]}"; do
  home="$test_tmp/render-$theme"
  next="$home/.local/state/omarchy/current/next-theme"
  mkdir -p "$next"
  cp "$ROOT/themes/$theme/colors.toml" "$next/colors.toml"
  HOME="$home" OMARCHY_PATH="$ROOT" PATH="$ROOT/bin:$PATH" "$ROOT/bin/omarchy-theme-set-templates"
  if grep -R -q '{{' "$next"; then
    fail "kids theme $theme renders every template placeholder"
  fi
  [[ -f $next/shell.toml ]] || fail "kids theme $theme generates shell.toml"
  [[ -f $next/hyprland.lua ]] || fail "kids theme $theme generates hyprland.lua"
done

pass "kids palettes render the generated theme files"

# A packaged-only extra theme disappears when the omarchy package is replaced;
# a copy in ~/.config/omarchy/themes survives that replacement.
packaged="$test_tmp/packaged"
home="$test_tmp/upgrade-home"
runtime="$test_tmp/runtime"
mkdir -p "$packaged/default" "$packaged/themes/tokyo-night" "$packaged/themes/cozy-night" \
  "$home/.config/omarchy/themes" "$runtime"
cp -a "$ROOT/default/themed" "$packaged/default/themed"
cp "$ROOT/themes/tokyo-night/colors.toml" "$packaged/themes/tokyo-night/colors.toml"
cp "$ROOT/themes/cozy-night/colors.toml" "$packaged/themes/cozy-night/colors.toml"

set_theme() {
  HOME="$home" XDG_RUNTIME_DIR="$runtime" OMARCHY_PATH="$packaged" PATH="$ROOT/bin:$PATH" \
    OMARCHY_THEME_HEADLESS=1 OMARCHY_THEME_SKIP_BACKGROUND=1 \
    "$ROOT/bin/omarchy-theme-set" "$1" >/dev/null
}

listed_themes() {
  HOME="$home" OMARCHY_PATH="$packaged" "$ROOT/bin/omarchy-theme-list"
}

set_theme "Cozy Night"
[[ $(<"$home/.local/state/omarchy/current/theme.name") == "cozy-night" ]] ||
  fail "cozy-night applies from the packaged tree"

listed=$(listed_themes)
[[ $listed == *"Cozy Night"* ]] || fail "the theme list includes a packaged kids theme"
[[ $listed == *"Tokyo Night"* ]] || fail "the theme list includes Tokyo Night"

rm -rf "$packaged/themes/cozy-night"
listed=$(listed_themes)
[[ $listed != *"Cozy Night"* ]] || fail "a packaged-only kids theme disappears when the package drops it"

HOME="$home" XDG_RUNTIME_DIR="$runtime" OMARCHY_PATH="$packaged" PATH="$ROOT/bin:$PATH" \
  OMARCHY_THEME_HEADLESS=1 bash "$ROOT/migrations/1787481315.sh" >/dev/null
[[ $(<"$home/.local/state/omarchy/current/theme.name") == "tokyo-night" ]] ||
  fail "restaging falls back to Tokyo Night when the current kids theme is gone"

pass "a packaged-only kids theme is lost when /usr/share/omarchy/themes is replaced"

mkdir -p "$packaged/themes/cozy-night" "$home/.config/omarchy/themes/cozy-night"
cp "$ROOT/themes/cozy-night/colors.toml" "$packaged/themes/cozy-night/colors.toml"
cp "$ROOT/themes/cozy-night/colors.toml" "$home/.config/omarchy/themes/cozy-night/colors.toml"
set_theme "Cozy Night"
rm -rf "$packaged/themes/cozy-night"

listed=$(listed_themes)
[[ $listed == *"Cozy Night"* ]] || fail "a user-copied kids theme remains listed after the package drops it"

HOME="$home" XDG_RUNTIME_DIR="$runtime" OMARCHY_PATH="$packaged" PATH="$ROOT/bin:$PATH" \
  OMARCHY_THEME_HEADLESS=1 bash "$ROOT/migrations/1787481315.sh" >/dev/null
[[ $(<"$home/.local/state/omarchy/current/theme.name") == "cozy-night" ]] ||
  fail "restaging keeps a user-copied kids theme after the package drops it"

set_theme "Cozy Night"
[[ -f $home/.local/state/omarchy/current/theme/colors.toml ]] ||
  fail "a user-copied kids theme still applies after the package drops it"

pass "a user-copied kids theme survives a package replacement"

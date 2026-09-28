#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

helper="$ROOT/install/helpers/limine-boot-editor.sh"
refresh="$ROOT/bin/omarchy-refresh-limine"
template="$ROOT/default/limine/limine.conf"
migration="$ROOT/migrations/1790600434.sh"

! grep -q 'editor_enabled' "$template" || fail "the shipped Limine template leaves the editor on for regular installs"
! grep -q 'editor_enabled' "$ROOT/default/limine/default.conf" || fail "/etc/default/limine is not where the editor setting lives"
! grep -Rq 'editor_enabled' "$ROOT/etc/limine-entry-tool.d" || fail "limine-entry-tool drop-ins do not set the boot-menu editor"
pass "regular Limine sources leave the boot-menu editor at Limine's default"

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT
stub_bin="$test_tmp/bin"
calls="$test_tmp/calls"
mkdir -p "$stub_bin" "$test_tmp/hooks" "$test_tmp/boot"
: >"$calls"

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$CALLS"
exec "$@"
SH
chmod +x "$stub_bin"/*

export CALLS="$calls"
export PATH="$stub_bin:$PATH"
export OMARCHY_PATH="$ROOT"

# The helper itself: insert, replace, and leave a missing file alone.
source "$helper"
export OMARCHY_LIMINE_CONF="$test_tmp/boot/limine.conf"
export OMARCHY_LIMINE_EDITOR_HOOK="$test_tmp/hooks/80-omarchy-child-boot-editor"

cp "$template" "$OMARCHY_LIMINE_CONF"
set_limine_boot_editor no
grep -Eq '^editor_enabled: no$' "$OMARCHY_LIMINE_CONF" || fail "the helper inserts editor_enabled: no into the shipped template"
# Inserted after hash_mismatch_panic, among the global options, not after entries.
panic_line=$(grep -n '^hash_mismatch_panic:' "$OMARCHY_LIMINE_CONF" | head -1 | cut -d: -f1)
editor_line=$(grep -n '^editor_enabled: no$' "$OMARCHY_LIMINE_CONF" | head -1 | cut -d: -f1)
(( editor_line == panic_line + 1 )) || fail "editor_enabled lands with the other global options"
saved=$(<"$OMARCHY_LIMINE_CONF")
set_limine_boot_editor no
[[ $(<"$OMARCHY_LIMINE_CONF") == "$saved" ]] || fail "a second apply leaves an already-disabled editor alone"
sed -i 's/^editor_enabled: no$/editor_enabled: yes/' "$OMARCHY_LIMINE_CONF"
set_limine_boot_editor no
grep -Eq '^editor_enabled: no$' "$OMARCHY_LIMINE_CONF" || fail "the helper turns an enabled editor off"
[[ $(grep -c '^editor_enabled:' "$OMARCHY_LIMINE_CONF") == 1 ]] || fail "the helper does not duplicate editor_enabled"

missing="$test_tmp/boot/missing.conf"
OMARCHY_LIMINE_CONF="$missing" set_limine_boot_editor no
[[ ! -e $missing ]] || fail "a missing Limine config is a no-op"
pass "the helper disables the editor idempotently without touching regular templates"

install_limine_boot_editor_hook
[[ -x $OMARCHY_LIMINE_EDITOR_HOOK ]] || fail "the post-save hook is installed executable"
grep -Fq 'set_limine_boot_editor no' "$OMARCHY_LIMINE_EDITOR_HOOK" || fail "the hook re-applies editor_enabled: no"
grep -Fq 'OMARCHY_PATH:-/usr/share/omarchy' "$OMARCHY_LIMINE_EDITOR_HOOK" || fail "the hook looks up the helper from the installed Omarchy path"

# The hook keys on the profile marker, not on PATH, so it still works when
# limine-entry-tool runs with a minimal environment.
sed -i 's/^editor_enabled: no$/editor_enabled: yes/' "$OMARCHY_LIMINE_CONF"
printf 'default\n' >"$test_tmp/profile"
OMARCHY_PROFILE_FILE="$test_tmp/profile" OMARCHY_PATH="$ROOT" OMARCHY_LIMINE_CONF="$OMARCHY_LIMINE_CONF" \
  bash "$OMARCHY_LIMINE_EDITOR_HOOK"
grep -Eq '^editor_enabled: yes$' "$OMARCHY_LIMINE_CONF" || fail "the hook leaves a regular install's editor on"

printf 'child\n' >"$test_tmp/profile"
OMARCHY_PROFILE_FILE="$test_tmp/profile" OMARCHY_PATH="$ROOT" OMARCHY_LIMINE_CONF="$OMARCHY_LIMINE_CONF" \
  bash "$OMARCHY_LIMINE_EDITOR_HOOK"
grep -Eq '^editor_enabled: no$' "$OMARCHY_LIMINE_CONF" || fail "the hook disables the editor on a child install"
pass "the limine-entry-tool post-save hook is child-only"

remove_limine_boot_editor_hook
[[ ! -e $OMARCHY_LIMINE_EDITOR_HOOK ]] || fail "removing the hook deletes it"
pass "the hook can be taken back off"

# omarchy-refresh-limine copies the regular template, then limine-update and
# limine-snapper-sync. A child refresh must still end with the editor off even
# when those tools rewrite the file without editor_enabled.
cat >"$stub_bin/omarchy-profile-child" <<'SH'
#!/bin/bash
[[ ${STUB_PROFILE:-child} == child ]]
SH
cat >"$stub_bin/limine-update" <<'SH'
#!/bin/bash
printf 'limine-update\n' >>"$CALLS"
{
  cat "$OMARCHY_PATH/default/limine/limine.conf"
  printf '\n/Omarchy\n'
} >"${OMARCHY_LIMINE_CONF:-/boot/limine.conf}"
SH
cat >"$stub_bin/limine-snapper-sync" <<'SH'
#!/bin/bash
printf 'limine-snapper-sync\n' >>"$CALLS"
SH
chmod +x "$stub_bin"/*

cp "$template" "$OMARCHY_LIMINE_CONF"
printf '\n/Keep me\n' >>"$OMARCHY_LIMINE_CONF"
: >"$calls"
STUB_PROFILE=child OMARCHY_LIMINE_CONF="$OMARCHY_LIMINE_CONF" OMARCHY_PATH="$ROOT" \
  PATH="$stub_bin:$PATH" bash "$refresh" >/dev/null
grep -Eq '^editor_enabled: no$' "$OMARCHY_LIMINE_CONF" || fail "omarchy-refresh-limine keeps the editor off on a child install"
grep -Fq '/Omarchy' "$OMARCHY_LIMINE_CONF" || fail "omarchy-refresh-limine still runs limine-update"
! grep -Fq '/Keep me' "$OMARCHY_LIMINE_CONF" || fail "omarchy-refresh-limine starts from the shipped template"
grep -Fxq 'limine-update' "$calls" || fail "omarchy-refresh-limine runs limine-update"
grep -Fxq 'limine-snapper-sync' "$calls" || fail "omarchy-refresh-limine runs limine-snapper-sync"
[[ -f ${OMARCHY_LIMINE_CONF}.bak ]] || fail "omarchy-refresh-limine backs up the previous config"
pass "omarchy-refresh-limine on a child install restores the template and then disables the editor"

: >"$calls"
cp "$template" "$OMARCHY_LIMINE_CONF"
STUB_PROFILE=default OMARCHY_LIMINE_CONF="$OMARCHY_LIMINE_CONF" OMARCHY_PATH="$ROOT" \
  PATH="$stub_bin:$PATH" bash "$refresh" >/dev/null
! grep -q 'editor_enabled' "$OMARCHY_LIMINE_CONF" || fail "omarchy-refresh-limine leaves a regular install's editor on"
grep -Fxq 'limine-update' "$calls" || fail "a regular refresh still rebuilds Limine"
pass "omarchy-refresh-limine on a regular install does not disable the editor"

# Existing child installs pick this up through the migration; others skip it.
cat >"$stub_bin/omarchy-profile-child" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$stub_bin/omarchy-profile-child"
cp "$template" "$OMARCHY_LIMINE_CONF"
: >"$calls"
OMARCHY_PATH="$ROOT" OMARCHY_LIMINE_CONF="$OMARCHY_LIMINE_CONF" \
  OMARCHY_LIMINE_EDITOR_HOOK="$OMARCHY_LIMINE_EDITOR_HOOK" \
  PATH="$stub_bin:$PATH" bash -euo pipefail "$migration"
! grep -q 'editor_enabled' "$OMARCHY_LIMINE_CONF" || fail "the migration leaves a regular install alone"
[[ ! -e $OMARCHY_LIMINE_EDITOR_HOOK ]] || fail "the migration does not install the hook off a child install"
pass "the migration is a no-op off the child profile"

cat >"$stub_bin/omarchy-profile-child" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$stub_bin/omarchy-profile-child"
cp "$template" "$OMARCHY_LIMINE_CONF"
OMARCHY_PATH="$ROOT" OMARCHY_LIMINE_CONF="$OMARCHY_LIMINE_CONF" \
  OMARCHY_LIMINE_EDITOR_HOOK="$OMARCHY_LIMINE_EDITOR_HOOK" \
  PATH="$stub_bin:$PATH" bash -euo pipefail "$migration"
grep -Eq '^editor_enabled: no$' "$OMARCHY_LIMINE_CONF" || fail "the migration disables the editor on a child install"
[[ -x $OMARCHY_LIMINE_EDITOR_HOOK ]] || fail "the migration installs the post-save hook on a child install"
OMARCHY_PATH="$ROOT" OMARCHY_LIMINE_CONF="$OMARCHY_LIMINE_CONF" \
  OMARCHY_LIMINE_EDITOR_HOOK="$OMARCHY_LIMINE_EDITOR_HOOK" \
  PATH="$stub_bin:$PATH" bash -euo pipefail "$migration"
[[ $(grep -c '^editor_enabled:' "$OMARCHY_LIMINE_CONF") == 1 ]] || fail "the migration is idempotent"
pass "the migration disables the editor on existing child installs"

#!/usr/bin/env bash
#
# clean-dokku.sh
#
# Integrates show-unlinked-postgres-dbs.sh, show-unlinked-mongo-dbs.sh,
# and clean-dokku-apps.sh into one combined interactive view:
#   - unlinked Postgres databases
#   - unlinked Mongo databases
#   - all dokku apps (P/M columns showing link counts)
# each under its own bracketed section header. Destroying a database
# or an app behaves exactly as in the standalone scripts -- see
# lib/show-unlinked-db-menu.sh and lib/dokku-apps-scan.sh.
#
# The full scan (all three sections) runs once at startup (and again
# only if "[ Refresh List ]" is selected) -- within a session, state is
# assumed not to change except through this script's own destroy
# actions, which are reflected locally without a full rescan.
#
# Requires: dokku (reachable via ssh/CLI on this host), whiptail or dialog

set -euo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
clean-dokku.sh

Interactively browse, in one combined list:
  - unlinked Postgres databases
  - unlinked Mongo databases
  - all dokku apps (with P/M columns showing how many Postgres/Mongo
    databases each is linked to: blank = none, x = one, * = two or more)

Selecting a database destroys it after confirmation. Selecting an app
destroys it after confirmation, first unlinking and destroying its own
linked databases (skipping, and reporting, any database still linked
to another app).

The list is scanned once at startup. Select "[ Refresh List ]" (pinned
at the top) to rescan on demand; destroying an item updates the list
in place without a full rescan.

Usage:
  clean-dokku.sh [-h|--help]

  -h, --help   Show this help message and exit
EOF
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo "Usage: clean-dokku.sh [-h|--help]" >&2
    exit 1
    ;;
esac

if command -v dialog >/dev/null 2>&1; then
  DIALOG_CMD=dialog
elif command -v whiptail >/dev/null 2>&1; then
  DIALOG_CMD=whiptail
else
  echo "Error: this script requires 'dialog' or 'whiptail' to be installed." >&2
  echo "  Debian/Ubuntu:  sudo apt-get install dialog   (or whiptail is usually preinstalled)" >&2
  exit 1
fi

if ! command -v dokku >/dev/null 2>&1; then
  echo "Error: 'dokku' command not found on this host." >&2
  exit 1
fi

trap 'clear' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/show-unlinked-db-menu.sh"
source "$SCRIPT_DIR/lib/dokku-apps-scan.sh"

REFRESH_LABEL="[ Refresh List ]"
PG_HEADER="[ Unlinked Postgres Dbs ]"
MONGO_HEADER="[ Unlinked Mongo Dbs ]"
APPS_HEADER="[ All Dokku Apps ]"

# Underlying per-section data, refreshed only by scan_all (startup or
# "[ Refresh List ]"); destroying an item updates these directly.
pg_names=()
mongo_names=()
app_rows=()
app_names=()

# The flat, ordered list of menu tags built from the arrays above.
# Postgres/Mongo db rows are prefixed "P "/"M " so a row's origin is
# always unambiguous from its tag text alone, even if (since the two
# are independent namespaces) a Postgres and a Mongo database ever
# happened to share the same bare name -- app rows can never collide
# with these since their own P/M columns only ever contain a space,
# 'x', or '*', never the literal letter P or M.
combo_tags=()

rebuild_combo() {
  combo_tags=("$REFRESH_LABEL" "$PG_HEADER")
  local name
  for name in "${pg_names[@]}"; do
    combo_tags+=("P $name")
  done
  combo_tags+=("$MONGO_HEADER")
  for name in "${mongo_names[@]}"; do
    combo_tags+=("M $name")
  done
  combo_tags+=("$APPS_HEADER")
  local row
  for row in "${app_rows[@]}"; do
    combo_tags+=("$row")
  done
}

scan_all() {
  scan_unlinked_service postgres Postgres pg_names
  scan_unlinked_service mongo MongoDB mongo_names
  scan_dokku_apps app_rows app_names
  rebuild_combo
}

scan_all

while true; do
  menu_items=()
  for tag in "${combo_tags[@]}"; do
    menu_items+=("$tag" "")
  done

  item_count=${#combo_tags[@]}
  menu_height=$(( item_count < 15 ? item_count : 15 ))

  term_lines=$(tput lines 2>/dev/null || echo 24)
  box_height=$(( menu_height + 11 ))
  max_box_height=$(( term_lines - 1 ))
  if [ "$box_height" -gt "$max_box_height" ]; then
    box_height=$max_box_height
    menu_height=$(( box_height - 11 ))
    [ "$menu_height" -lt 1 ] && menu_height=1
  fi

  prompt="Up/Down arrows (or PageUp/PageDown) to scroll \nTab to move between fields\nPress Enter (or choose OK) to select an item to destroy\nPress Escape (or choose Cancel) to exit"

  if choice=$("$DIALOG_CMD" --clear \
      --backtitle "Clean Dokku (Postgres + Mongo + Apps)" \
      --title "Select an Item to Destroy" \
      --menu "$prompt" \
      --default-item "$REFRESH_LABEL" \
      "$box_height" 70 "$menu_height" \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3); then
    :
  else
    break
  fi

  case "$choice" in
    "$REFRESH_LABEL")
      scan_all
      continue
      ;;
    "$PG_HEADER"|"$MONGO_HEADER"|"$APPS_HEADER")
      continue
      ;;
    "P "*)
      name="${choice#P }"
      if "$DIALOG_CMD" --clear \
          --title "Confirm Destroy" \
          --yesno "Are you SURE you want to permanently destroy the Postgres database:\n\n  ${name}\n\nThis action cannot be undone." 12 60; then
        clear
        if destroy_unlinked_service postgres Postgres "$name"; then
          remaining=()
          for n in "${pg_names[@]}"; do
            [ "$n" != "$name" ] && remaining+=("$n")
          done
          pg_names=("${remaining[@]}")
          rebuild_combo
        fi
        read -r -p "Press Enter to continue..." _
      fi
      ;;
    "M "*)
      name="${choice#M }"
      if "$DIALOG_CMD" --clear \
          --title "Confirm Destroy" \
          --yesno "Are you SURE you want to permanently destroy the MongoDB database:\n\n  ${name}\n\nThis action cannot be undone." 12 60; then
        clear
        if destroy_unlinked_service mongo MongoDB "$name"; then
          remaining=()
          for n in "${mongo_names[@]}"; do
            [ "$n" != "$name" ] && remaining+=("$n")
          done
          mongo_names=("${remaining[@]}")
          rebuild_combo
        fi
        read -r -p "Press Enter to continue..." _
      fi
      ;;
    *)
      name="${choice:4}"
      if "$DIALOG_CMD" --clear \
          --title "Confirm Destroy" \
          --yesno "Are you SURE you want to permanently destroy the app:\n\n  ${name}\n\nThis will also unlink and destroy any Postgres/Mongo databases linked only to this app.\n\nThis action cannot be undone." 14 70; then
        clear
        echo "Destroying app '${name}'..."
        if destroy_dokku_app "$name"; then
          new_rows=()
          new_names=()
          for i in "${!app_names[@]}"; do
            if [ "${app_names[$i]}" != "$name" ]; then
              new_rows+=("${app_rows[$i]}")
              new_names+=("${app_names[$i]}")
            fi
          done
          app_rows=("${new_rows[@]}")
          app_names=("${new_names[@]}")
          rebuild_combo
        fi
        read -r -p "Press Enter to continue..." _
      fi
      ;;
  esac
done

echo "Done."

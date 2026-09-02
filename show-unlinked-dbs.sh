#!/usr/bin/env bash
#
# show-unlinked-dbs.sh
#
# Interactive (curses-based) tool for browsing dokku postgres databases
# that have no app links, and destroying a selected one, with a
# confirmation prompt. Linked databases are never shown, since dokku
# refuses to destroy a database that still has links.
#
# The list of unlinked databases is scanned once at startup (and again
# only if "[ Refresh List ]" is selected) -- within a session, database
# links are assumed not to change except through this script's own
# destroy action, which is reflected locally without a full rescan.
#
# Requires: dokku (reachable via ssh/CLI on this host), whiptail or dialog

set -euo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
show-unlinked-dbs.sh

Interactively browse dokku postgres databases that have no app links,
and destroy a selected one after confirmation. Databases that are
linked to an app are never shown, since dokku refuses to destroy a
database that still has links.

The list is scanned once at startup. Select "[ Refresh List ]" (pinned
at the top of the list) to rescan on demand; destroying a database
updates the list in place without a full rescan.

Usage:
  show-unlinked-dbs.sh [-h|--help]

  -h, --help   Show this help message and exit
EOF
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo "Usage: show-unlinked-dbs.sh [-h|--help]" >&2
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

cleanup() {
  clear
}
trap cleanup EXIT

REFRESH_LABEL="[ Refresh List ]"

db_names=()

# `dokku postgres:list` prints a "=====> Postgres services" header line
# followed by one database name per line (no columns). Populates the
# global db_names array with just the unlinked ones.
#
# Note: all progress output below is written to fd 2, not fd 1 -- fd 1 is
# reserved for normal script output. Running a curses dialog (e.g.
# --infobox) here, immediately before the --menu dialog in the caller,
# has been observed to corrupt the menu's rendering (borders and buttons
# draw, but the list items do not) -- so this progress indicator
# deliberately uses plain terminal output instead of a curses widget.
scan_db_names() {
  local raw
  raw=$(dokku postgres:list 2>&1) || raw=""

  if ! grep -q '^=====>' <<<"$raw"; then
    "$DIALOG_CMD" --title "Error" \
      --msgbox "Could not list postgres services:\n\n${raw}" 15 70
    exit 1
  fi

  local all_names=()
  while IFS= read -r line; do
    line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")"
    [ -z "$line" ] && continue
    all_names+=("$line")
  done < <(tail -n +2 <<<"$raw")

  clear >&2
  local total=${#all_names[@]}
  local count=0
  local bar_width=40
  local unlinked=()
  for name in "${all_names[@]}"; do
    count=$((count + 1))
    local pct=0
    [ "$total" -gt 0 ] && pct=$(( count * 100 / total ))
    local filled=$(( pct * bar_width / 100 ))
    local bar
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /#}"
    printf '\rChecking for unlinked postgres databases: [%-*s] %3d%% (%d/%d) %-30.30s\033[K' \
      "$bar_width" "$bar" "$pct" "$count" "$total" "$name" >&2
    if [ -z "$(dokku postgres:links "$name" 2>/dev/null)" ]; then
      unlinked+=("$name")
    fi
  done
  printf '\n' >&2

  db_names=("${unlinked[@]}")
}

scan_db_names

while true; do
  menu_items=("$REFRESH_LABEL" "")
  for name in "${db_names[@]}"; do
    menu_items+=("$name" "")
  done

  item_count=$(( ${#db_names[@]} + 1 ))
  menu_height=$(( item_count < 15 ? item_count : 15 ))

  term_lines=$(tput lines 2>/dev/null || echo 24)
  box_height=$(( menu_height + 11 ))
  max_box_height=$(( term_lines - 1 ))
  if [ "$box_height" -gt "$max_box_height" ]; then
    box_height=$max_box_height
    menu_height=$(( box_height - 11 ))
    [ "$menu_height" -lt 1 ] && menu_height=1
  fi

  prompt="Up/Down arrows (or PageUp/PageDown) to scroll \nTab to move between fields\nPress Enter (or choose OK) to select a db to delete\nPress Escape (or choose Cancel) to exit"

  if choice=$("$DIALOG_CMD" --clear \
      --backtitle "Show Unlinked Postgres Databases" \
      --title "Select an Unlinked Postgres Database to Destroy" \
      --menu "$prompt" \
      "$box_height" 70 "$menu_height" \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3); then
    if [ "$choice" = "$REFRESH_LABEL" ]; then
      scan_db_names
      continue
    fi
  else
    break
  fi

  if "$DIALOG_CMD" --clear \
      --title "Confirm Destroy" \
      --yesno "Are you SURE you want to permanently destroy the postgres database:\n\n  ${choice}\n\nThis action cannot be undone." 12 60; then
    clear
    echo "Destroying postgres database '${choice}'..."
    if dokku postgres:destroy "$choice" --force; then
      echo "'${choice}' destroyed."
      remaining=()
      for name in "${db_names[@]}"; do
        [ "$name" != "$choice" ] && remaining+=("$name")
      done
      db_names=("${remaining[@]}")
    else
      echo "Failed to destroy '${choice}'." >&2
    fi
    read -r -p "Press Enter to continue..." _
  fi
done

echo "Done."

#!/usr/bin/env bash
#
# clean-postgres-dbs.sh
#
# Interactive (curses-based) tool for browsing dokku postgres databases
# and destroying a selected one, with a confirmation prompt.
#
# Requires: dokku (reachable via ssh/CLI on this host), dialog

set -euo pipefail

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

# `dokku postgres:list` prints a "=====> Postgres services" header line
# followed by one database name per line (no columns).
fetch_db_names() {
  local raw
  raw=$(dokku postgres:list 2>&1) || raw=""

  if ! grep -q '^=====>' <<<"$raw"; then
    "$DIALOG_CMD" --title "Error" \
      --msgbox "Could not list postgres services:\n\n${raw}" 15 70
    return 1
  fi

  local names=()
  while IFS= read -r line; do
    line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")"
    [ -z "$line" ] && continue
    names+=("$line")
  done < <(tail -n +2 <<<"$raw")

  if [ "${#names[@]}" -eq 0 ]; then
    "$DIALOG_CMD" --title "No Postgres Databases" \
      --msgbox "No postgres services were found." 8 50
    return 1
  fi

  printf '%s\n' "${names[@]}"
}

while true; do
  mapfile -t db_names < <(fetch_db_names) || break

  if [ "${#db_names[@]}" -eq 0 ]; then
    break
  fi

  menu_items=()
  for name in "${db_names[@]}"; do
    menu_items+=("$name" "")
  done

  menu_height=$(( ${#db_names[@]} < 15 ? ${#db_names[@]} : 15 ))

  if choice=$("$DIALOG_CMD" --clear \
      --backtitle "Dokku Postgres Database Cleaner" \
      --title "Select a Postgres Database to Destroy" \
      --menu "Use Up/Down (or PageUp/PageDown) to scroll, Enter to select, Esc/Cancel to quit:" \
      $(( menu_height + 8 )) 60 "$menu_height" \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3); then
    : # a database was selected, $choice holds its name
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
    else
      echo "Failed to destroy '${choice}'." >&2
    fi
    read -r -p "Press Enter to continue..." _
  fi
done

echo "Done."

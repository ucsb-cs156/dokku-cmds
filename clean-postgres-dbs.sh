#!/usr/bin/env bash
#
# clean-postgres-dbs.sh
#
# Interactive (curses-based) tool for browsing dokku postgres databases
# and destroying a selected one, with a confirmation prompt.
#
# By default, only databases with no app links are shown, since a linked
# database is in active use. Pass --show-linked to also list linked ones.
#
# Requires: dokku (reachable via ssh/CLI on this host), dialog

set -euo pipefail

SHOW_LINKED=false
while [ $# -gt 0 ]; do
  case "$1" in
    --show-linked)
      SHOW_LINKED=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--show-linked]"
      echo
      echo "  --show-linked   Also list databases that are linked to an app"
      echo "                  (hidden by default, since they are in active use)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--show-linked]" >&2
      exit 1
      ;;
  esac
done

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

  # Note: all progress output below is written to fd 2, not fd 1 -- fd 1 is
  # reserved for the final list of names, read by the caller via
  # `mapfile -t db_names < <(fetch_db_names)`. Running a curses dialog (e.g.
  # --infobox) here, immediately before the --menu dialog in the caller,
  # has been observed to corrupt the menu's rendering (borders and buttons
  # draw, but the list items do not) -- so this progress indicator
  # deliberately uses plain terminal output instead of a curses widget.
  if [ "$SHOW_LINKED" = false ]; then
    clear >&2
    local total=${#names[@]}
    local count=0
    local bar_width=40
    local unlinked=()
    for name in "${names[@]}"; do
      count=$((count + 1))
      local pct=$(( count * 100 / total ))
      local filled=$(( pct * bar_width / 100 ))
      local bar
      printf -v bar '%*s' "$filled" ''
      bar="${bar// /#}"
      printf '\rChecking for linked databases: [%-*s] %3d%% (%d/%d) %-30.30s\033[K' \
        "$bar_width" "$bar" "$pct" "$count" "$total" "$name" >&2
      if [ -z "$(dokku postgres:links "$name" 2>/dev/null)" ]; then
        unlinked+=("$name")
      fi
    done
    printf '\n' >&2
    names=("${unlinked[@]}")
  fi

  if [ "${#names[@]}" -eq 0 ]; then
    if [ "$SHOW_LINKED" = false ]; then
      "$DIALOG_CMD" --title "No Postgres Databases" \
        --msgbox "No unlinked postgres databases were found.\n\nRun with --show-linked to also see databases that are linked to an app." 10 60
    else
      "$DIALOG_CMD" --title "No Postgres Databases" \
        --msgbox "No postgres services were found." 8 50
    fi
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

  term_lines=$(tput lines 2>/dev/null || echo 24)
  box_height=$(( menu_height + 9 ))
  max_box_height=$(( term_lines - 1 ))
  if [ "$box_height" -gt "$max_box_height" ]; then
    box_height=$max_box_height
    menu_height=$(( box_height - 9 ))
    [ "$menu_height" -lt 1 ] && menu_height=1
  fi

  if [ "$SHOW_LINKED" = true ]; then
    backtitle="Dokku Postgres Database Cleaner (showing all databases, including linked)"
  else
    backtitle="Dokku Postgres Database Cleaner (showing unlinked databases only)"
  fi

  if choice=$("$DIALOG_CMD" --clear \
      --backtitle "$backtitle" \
      --title "Select a Postgres Database to Destroy" \
      --menu "Use Up/Down (or PageUp/PageDown) to scroll, Enter to select, Press Escape to Exit." \
      "$box_height" 60 "$menu_height" \
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

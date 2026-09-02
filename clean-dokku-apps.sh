#!/usr/bin/env bash
#
# clean-dokku-apps.sh
#
# Interactively browse all dokku apps in a table showing how many
# Postgres (P) and Mongo (M) database services each app is linked to
# (blank = none, x = one, * = two or more), and destroy a selected app
# after confirmation.
#
# Destroying an app unlinks and destroys each of its linked Postgres
# and Mongo databases first (skipping, and reporting, any database
# that turns out to still be linked to another app), then destroys the
# app itself.
#
# The list is scanned once at startup (and again only if
# "[ Refresh List ]" is selected) -- within a session, app/link state
# is assumed not to change except through this script's own destroy
# action, which is reflected locally without a full rescan.
#
# Requires: dokku (reachable via ssh/CLI on this host), whiptail or dialog

set -euo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
clean-dokku-apps.sh

Interactively browse all dokku apps in a table showing how many
Postgres (P) and Mongo (M) database services each app is linked to
(blank = none, x = one, * = two or more), and destroy a selected app
after confirmation.

Destroying an app unlinks and destroys each of its linked Postgres and
Mongo databases first (skipping, and reporting, any database that is
still linked to another app), then destroys the app itself.

The list is scanned once at startup. Select "[ Refresh List ]" (pinned
at the top of the list) to rescan on demand; destroying an app updates
the list in place without a full rescan.

Usage:
  clean-dokku-apps.sh [-h|--help]

  -h, --help   Show this help message and exit
EOF
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo "Usage: clean-dokku-apps.sh [-h|--help]" >&2
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

REFRESH_LABEL="[ Refresh List ]"
HEADER_LABEL="P M App Name"

# Parallel arrays: app_rows[i] is the formatted "P M appname" display
# string for app_names[i]. Rebuilt by scan_apps; destroying an app
# removes its entry from both without rescanning everything else.
app_rows=()
app_names=()

link_marker() {
  local count="$1"
  if [ "$count" -ge 2 ]; then
    echo '*'
  elif [ "$count" -eq 1 ]; then
    echo 'x'
  else
    echo ' '
  fi
}

# `dokku apps:list` prints a "=====> My Apps" header line followed by
# one app name per line (no columns). For each app, the Postgres/Mongo
# link counts come from `<type>:app-links <app>` (one linked service
# name per line, empty if none).
#
# Note: all progress output below is written to fd 2, not fd 1 -- fd 1
# is reserved for normal script output. See show-unlinked-*-dbs.sh /
# lib/show-unlinked-db-menu.sh for why this avoids a curses --infobox
# immediately before the --menu dialog below.
scan_apps() {
  local raw
  raw=$(dokku apps:list 2>&1) || raw=""

  if ! grep -q '^=====>' <<<"$raw"; then
    "$DIALOG_CMD" --title "Error" \
      --msgbox "Could not list apps:\n\n${raw}" 15 70
    exit 1
  fi

  local all_apps=()
  while IFS= read -r line; do
    line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")"
    [ -z "$line" ] && continue
    all_apps+=("$line")
  done < <(tail -n +2 <<<"$raw")

  clear >&2
  local total=${#all_apps[@]}
  local count=0
  local bar_width=40

  app_rows=()
  app_names=()

  for app in "${all_apps[@]}"; do
    count=$((count + 1))
    local pct=0
    [ "$total" -gt 0 ] && pct=$(( count * 100 / total ))
    local filled=$(( pct * bar_width / 100 ))
    local bar
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /#}"
    printf '\rScanning apps for database links: [%-*s] %3d%% (%d/%d) %-30.30s\033[K' \
      "$bar_width" "$bar" "$pct" "$count" "$total" "$app" >&2

    local pcount mcount
    pcount=$(dokku postgres:app-links "$app" 2>/dev/null | grep -c .) || pcount=0
    mcount=$(dokku mongo:app-links "$app" 2>/dev/null | grep -c .) || mcount=0

    local pchar mchar
    pchar=$(link_marker "$pcount")
    mchar=$(link_marker "$mcount")

    app_rows+=("${pchar} ${mchar} ${app}")
    app_names+=("$app")
  done
  printf '\n' >&2
}

scan_apps

while true; do
  menu_items=("$HEADER_LABEL" "" "$REFRESH_LABEL" "")
  for row in "${app_rows[@]}"; do
    menu_items+=("$row" "")
  done

  item_count=$(( ${#app_rows[@]} + 2 ))
  menu_height=$(( item_count < 15 ? item_count : 15 ))

  term_lines=$(tput lines 2>/dev/null || echo 24)
  box_height=$(( menu_height + 11 ))
  max_box_height=$(( term_lines - 1 ))
  if [ "$box_height" -gt "$max_box_height" ]; then
    box_height=$max_box_height
    menu_height=$(( box_height - 11 ))
    [ "$menu_height" -lt 1 ] && menu_height=1
  fi

  prompt="Up/Down arrows (or PageUp/PageDown) to scroll \nTab to move between fields\nPress Enter (or choose OK) to select an app to destroy\nPress Escape (or choose Cancel) to exit"

  if choice=$("$DIALOG_CMD" --clear \
      --backtitle "Clean Dokku Apps" \
      --title "Select a Dokku App to Destroy" \
      --menu "$prompt" \
      --default-item "$REFRESH_LABEL" \
      "$box_height" 70 "$menu_height" \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3); then
    if [ "$choice" = "$REFRESH_LABEL" ]; then
      scan_apps
      continue
    fi
    if [ "$choice" = "$HEADER_LABEL" ]; then
      continue
    fi
  else
    break
  fi

  app="${choice:4}"

  if "$DIALOG_CMD" --clear \
      --title "Confirm Destroy" \
      --yesno "Are you SURE you want to permanently destroy the app:\n\n  ${app}\n\nThis will also unlink and destroy any Postgres/Mongo databases linked only to this app.\n\nThis action cannot be undone." 14 70; then
    clear
    echo "Destroying app '${app}'..."

    pg_links=$(dokku postgres:app-links "$app" 2>/dev/null || true)
    if [ -n "$pg_links" ]; then
      while IFS= read -r db; do
        [ -z "$db" ] && continue
        if dokku postgres:unlink "$db" "$app" >/dev/null 2>&1; then
          if dokku postgres:destroy "$db" --force >/dev/null 2>&1; then
            echo "  Destroyed postgres database '$db'."
          else
            echo "  Could not destroy postgres database '$db' (still linked to another app?)."
          fi
        else
          echo "  Could not unlink postgres database '$db' from '$app'; leaving it as is."
        fi
      done <<< "$pg_links"
    fi

    mongo_links=$(dokku mongo:app-links "$app" 2>/dev/null || true)
    if [ -n "$mongo_links" ]; then
      while IFS= read -r db; do
        [ -z "$db" ] && continue
        if dokku mongo:unlink "$db" "$app" >/dev/null 2>&1; then
          if dokku mongo:destroy "$db" --force >/dev/null 2>&1; then
            echo "  Destroyed mongo database '$db'."
          else
            echo "  Could not destroy mongo database '$db' (still linked to another app?)."
          fi
        else
          echo "  Could not unlink mongo database '$db' from '$app'; leaving it as is."
        fi
      done <<< "$mongo_links"
    fi

    if dokku apps:destroy "$app" --force; then
      echo "'${app}' destroyed."
      new_rows=()
      new_names=()
      for i in "${!app_names[@]}"; do
        if [ "${app_names[$i]}" != "$app" ]; then
          new_rows+=("${app_rows[$i]}")
          new_names+=("${app_names[$i]}")
        fi
      done
      app_rows=("${new_rows[@]}")
      app_names=("${new_names[@]}")
    else
      echo "Failed to destroy app '${app}'." >&2
    fi
    read -r -p "Press Enter to continue..." _
  fi
done

echo "Done."

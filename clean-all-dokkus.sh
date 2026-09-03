#!/usr/bin/env bash
#
# clean-all-dokkus.sh
#
# Runs clean-dokku.sh's combined view (unlinked Postgres dbs, unlinked
# Mongo dbs, all apps) across every dokku host in lib/dokku-hosts.sh,
# each under its own "[<host>]" section header, itself containing the
# same three bracketed sub-headers as clean-dokku.sh.
#
# Must be run from a host with passwordless SSH access to every host
# in that list (this is assumed, not checked beyond a per-host
# "UNREACHABLE" note if a host's scan fails).
#
# The per-host scans run in parallel (one background job per host) to
# keep the one-time startup cost close to the slowest single host,
# rather than the sum of all of them.
#
# Because a Postgres/Mongo database name (or an app name) could exist
# identically on more than one of these independent dokku hosts, every
# row is prefixed with its 2-digit host number in addition to the P/M
# type marker used by clean-dokku.sh -- see DESIGN_NOTES.md.
#
# The full scan runs once at startup (and again only if
# "[ Refresh List ]" is selected) -- within a session, state is assumed
# not to change except through this script's own destroy actions,
# which are reflected locally without a full rescan.
#
# Requires: whiptail or dialog, and passwordless ssh to every host in
# lib/dokku-hosts.sh (this control host does not need dokku installed
# locally -- every dokku call in this script targets a remote host).

set -euo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
clean-all-dokkus.sh

Runs the same combined view as clean-dokku.sh (unlinked Postgres dbs,
unlinked Mongo dbs, all apps with P/M link-count columns) across every
dokku host configured in lib/dokku-hosts.sh, each under its own
"[<host>]" section header.

Must be run from a host with passwordless SSH access to every one of
those hosts. Per-host scans run in parallel to keep the one-time
startup scan fast.

Selecting a database or an app destroys it (on its own host) after
confirmation, exactly as in clean-dokku.sh.

The list is scanned once at startup. Select "[ Refresh List ]" (pinned
at the top) to rescan on demand; destroying an item updates the list
in place without a full rescan.

Usage:
  clean-all-dokkus.sh [-h|--help]

  -h, --help   Show this help message and exit
EOF
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo "Usage: clean-all-dokkus.sh [-h|--help]" >&2
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

trap 'clear' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/dokku-hosts.sh"
source "$SCRIPT_DIR/lib/show-unlinked-db-menu.sh"
source "$SCRIPT_DIR/lib/dokku-apps-scan.sh"

REFRESH_LABEL="[ Refresh List ]"
PG_HEADER="[ Unlinked Postgres Dbs ]"
MONGO_HEADER="[ Unlinked Mongo Dbs ]"
APPS_HEADER="[ All Dokku Apps ]"

# Flat, all-hosts-combined arrays. Each entry is already host-prefixed
# ("<NN> P <name>", "<NN> M <name>", "<NN> <P> <M> <appname>"), so no
# separate per-host storage is needed -- see DESIGN_NOTES.md on why the
# host number has to be part of the tag text itself, not just tracked
# on the side.
pg_rows=()
mongo_rows=()
app_rows=()

declare -A unreachable_hosts=()

combo_tags=()

rebuild_combo() {
  combo_tags=("$REFRESH_LABEL")
  local i hostnum host row
  for ((i = DOKKU_HOST_FIRST; i <= DOKKU_HOST_LAST; i++)); do
    hostnum=$(printf '%02d' "$i")
    host="${DOKKU_HOST_PREFIX}${hostnum}${DOKKU_HOST_SUFFIX}"
    if [ -n "${unreachable_hosts[$hostnum]:-}" ]; then
      combo_tags+=("[$host -- UNREACHABLE]")
      continue
    fi
    combo_tags+=("[$host]")
    combo_tags+=("$PG_HEADER")
    for row in "${pg_rows[@]}"; do
      [[ "$row" == "$hostnum "* ]] && combo_tags+=("$row")
    done
    combo_tags+=("$MONGO_HEADER")
    for row in "${mongo_rows[@]}"; do
      [[ "$row" == "$hostnum "* ]] && combo_tags+=("$row")
    done
    combo_tags+=("$APPS_HEADER")
    for row in "${app_rows[@]}"; do
      [[ "$row" == "$hostnum "* ]] && combo_tags+=("$row")
    done
  done
}

# _scan_one_host_to_file <host> <outfile>
#
# Scans a single host's unlinked Postgres/Mongo dbs and apps table,
# writing plain-text results to <outfile>. Meant to be run in the
# background (once per host, in parallel) with its stderr discarded --
# scan_unlinked_service/scan_dokku_apps never pop a dialog themselves
# on failure (they just return non-zero), so this is safe to run
# unattended; a failure is recorded as a single "UNREACHABLE" line.
_scan_one_host_to_file() {
  local host="$1" outfile="$2"
  local DOKKU_TARGET_HOST="$host"
  local pg=() mongo=() rows=() names=()
  local ok=0
  scan_unlinked_service postgres Postgres pg || ok=1
  scan_unlinked_service mongo MongoDB mongo || ok=1
  scan_dokku_apps rows names || ok=1

  local n j
  {
    [ "$ok" -ne 0 ] && echo "UNREACHABLE"
    for n in "${pg[@]}"; do echo "PG:$n"; done
    for n in "${mongo[@]}"; do echo "MONGO:$n"; done
    for j in "${!names[@]}"; do echo "APP:${rows[$j]}"; done
  } > "$outfile.tmp"
  # Renamed into place only once fully written, so the main process can
  # tell "started" (nothing written yet, or the file doesn't exist)
  # apart from "finished" (the real filename exists) by polling for it
  # -- a plain `> "$outfile"` redirection would instead create the
  # (empty) file the instant this job starts, well before it's done.
  mv "$outfile.tmp" "$outfile"
}

scan_all() {
  local tmpdir
  tmpdir=$(mktemp -d)

  local host_count=$(( DOKKU_HOST_LAST - DOKKU_HOST_FIRST + 1 ))

  local i hostnum host
  for ((i = DOKKU_HOST_FIRST; i <= DOKKU_HOST_LAST; i++)); do
    hostnum=$(printf '%02d' "$i")
    host="${DOKKU_HOST_PREFIX}${hostnum}${DOKKU_HOST_SUFFIX}"
    _scan_one_host_to_file "$host" "$tmpdir/$hostnum" >/dev/null 2>&1 &
  done

  # Live progress while the 19 background jobs run: this can take over
  # a minute, and with each job's own progress bar discarded (19
  # interleaved bars would be unreadable), a single static "please
  # wait" message for that whole stretch looks indistinguishable from a
  # hang. Poll for completion markers (see _scan_one_host_to_file's
  # write-then-rename) instead of a real progress bar, since we can't
  # know in advance how far along any individual host's scan is.
  local start_ts elapsed finished bar_width filled bar
  start_ts=$(date +%s)
  bar_width=40
  while :; do
    finished=$(find "$tmpdir" -maxdepth 1 -type f ! -name '*.tmp' 2>/dev/null | wc -l)
    elapsed=$(( $(date +%s) - start_ts ))
    filled=$(( finished * bar_width / host_count ))
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /#}"
    printf '\rScanning %d dokku hosts in parallel: [%-*s] %d/%d complete (%ds elapsed)\033[K' \
      "$host_count" "$bar_width" "$bar" "$finished" "$host_count" "$elapsed" >&2
    [ "$finished" -ge "$host_count" ] && break
    sleep 1
  done
  printf '\n' >&2
  wait

  pg_rows=()
  mongo_rows=()
  app_rows=()
  unreachable_hosts=()

  for ((i = DOKKU_HOST_FIRST; i <= DOKKU_HOST_LAST; i++)); do
    hostnum=$(printf '%02d' "$i")
    local outfile="$tmpdir/$hostnum"
    [ -f "$outfile" ] || { unreachable_hosts[$hostnum]=1; continue; }
    while IFS= read -r line; do
      case "$line" in
        UNREACHABLE)
          unreachable_hosts[$hostnum]=1
          ;;
        PG:*)
          pg_rows+=("$hostnum P ${line#PG:}")
          ;;
        MONGO:*)
          mongo_rows+=("$hostnum M ${line#MONGO:}")
          ;;
        APP:*)
          app_rows+=("$hostnum ${line#APP:}")
          ;;
      esac
    done < "$outfile"
  done

  rm -rf "$tmpdir"
  echo "Scan complete." >&2
  rebuild_combo
}

scan_all

# Which tag to highlight when the menu (re)opens. Defaults to keeping
# the cursor on whatever was just selected; after a destroy, moved to
# whatever now sits at that same position in combo_tags (typically the
# next item), so scrolling through all 19 hosts and deleting things as
# you go doesn't mean scrolling all the way back after every destroy.
default_item="$REFRESH_LABEL"

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
      --backtitle "Clean All Dokkus (Postgres + Mongo + Apps, every host)" \
      --title "Select an Item to Destroy" \
      --menu "$prompt" \
      --default-item "$default_item" \
      "$box_height" 70 "$menu_height" \
      "${menu_items[@]}" \
      3>&1 1>&2 2>&3); then
    default_item="$choice"
  else
    break
  fi

  idx=-1
  for i in "${!combo_tags[@]}"; do
    [ "${combo_tags[$i]}" = "$choice" ] && idx=$i && break
  done

  case "$choice" in
    "$REFRESH_LABEL")
      scan_all
      default_item="$REFRESH_LABEL"
      continue
      ;;
    \[*\])
      continue
      ;;
    [0-9][0-9]" P "*)
      hostnum="${choice:0:2}"
      name="${choice:5}"
      host="${DOKKU_HOST_PREFIX}${hostnum}${DOKKU_HOST_SUFFIX}"
      if "$DIALOG_CMD" --clear \
          --title "Confirm Destroy" \
          --yesno "Are you SURE you want to permanently destroy the Postgres database:\n\n  ${name}\n\non host:\n\n  ${host}\n\nThis action cannot be undone." 14 60; then
        clear
        DOKKU_TARGET_HOST="$host"
        if destroy_unlinked_service postgres Postgres "$name"; then
          remaining=()
          for r in "${pg_rows[@]}"; do
            [ "$r" != "$choice" ] && remaining+=("$r")
          done
          pg_rows=("${remaining[@]}")
          rebuild_combo
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#combo_tags[@]}" ]; then
            default_item="${combo_tags[$idx]}"
          else
            default_item="${combo_tags[$((${#combo_tags[@]} - 1))]}"
          fi
        fi
        unset DOKKU_TARGET_HOST
        read -r -p "Press Enter to continue..." _
      fi
      ;;
    [0-9][0-9]" M "*)
      hostnum="${choice:0:2}"
      name="${choice:5}"
      host="${DOKKU_HOST_PREFIX}${hostnum}${DOKKU_HOST_SUFFIX}"
      if "$DIALOG_CMD" --clear \
          --title "Confirm Destroy" \
          --yesno "Are you SURE you want to permanently destroy the MongoDB database:\n\n  ${name}\n\non host:\n\n  ${host}\n\nThis action cannot be undone." 14 60; then
        clear
        DOKKU_TARGET_HOST="$host"
        if destroy_unlinked_service mongo MongoDB "$name"; then
          remaining=()
          for r in "${mongo_rows[@]}"; do
            [ "$r" != "$choice" ] && remaining+=("$r")
          done
          mongo_rows=("${remaining[@]}")
          rebuild_combo
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#combo_tags[@]}" ]; then
            default_item="${combo_tags[$idx]}"
          else
            default_item="${combo_tags[$((${#combo_tags[@]} - 1))]}"
          fi
        fi
        unset DOKKU_TARGET_HOST
        read -r -p "Press Enter to continue..." _
      fi
      ;;
    *)
      hostnum="${choice:0:2}"
      name="${choice:7}"
      host="${DOKKU_HOST_PREFIX}${hostnum}${DOKKU_HOST_SUFFIX}"
      if "$DIALOG_CMD" --clear \
          --title "Confirm Destroy" \
          --yesno "Are you SURE you want to permanently destroy the app:\n\n  ${name}\n\non host:\n\n  ${host}\n\nThis will also unlink and destroy any Postgres/Mongo databases linked only to this app.\n\nThis action cannot be undone." 16 70; then
        clear
        echo "Destroying app '${name}' on ${host}..."
        DOKKU_TARGET_HOST="$host"
        if destroy_dokku_app "$name"; then
          remaining=()
          for r in "${app_rows[@]}"; do
            [ "$r" != "$choice" ] && remaining+=("$r")
          done
          app_rows=("${remaining[@]}")
          rebuild_combo
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#combo_tags[@]}" ]; then
            default_item="${combo_tags[$idx]}"
          else
            default_item="${combo_tags[$((${#combo_tags[@]} - 1))]}"
          fi
        fi
        unset DOKKU_TARGET_HOST
        read -r -p "Press Enter to continue..." _
      fi
      ;;
  esac
done

echo "Done."

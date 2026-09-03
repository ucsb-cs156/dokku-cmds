#!/usr/bin/env bash
#
# lib/show-unlinked-db-menu.sh
#
# Shared implementation for interactively browsing dokku database
# services of a given type (postgres, mongo, ...) that have no app
# links, and destroying a selected one after confirmation. Linked
# services are never shown, since dokku refuses to destroy a service
# that still has links.
#
# The list is scanned once at startup (and again only if
# "[ Refresh List ]" is selected) -- within a session, service links
# are assumed not to change except through this script's own destroy
# action, which is reflected locally without a full rescan.
#
# Sourced by show-unlinked-<type>-dbs.sh wrapper scripts, which must set
# SERVICE_CMD (the dokku command prefix, e.g. "postgres") and
# SERVICE_LABEL (a human-readable name, e.g. "Postgres") before sourcing,
# then call run_unlinked_db_menu "$@".
#
# Also exposes scan_unlinked_service and destroy_unlinked_service as
# standalone functions (used directly by clean-dokku.sh, which combines
# this scan with others into one menu rather than running its own
# interactive loop per service type, and by clean-all-dokkus.sh, which
# runs them against a remote host via run_dokku -- see lib/dokku-hosts.sh).

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LIB_DIR/dokku-hosts.sh"

# scan_unlinked_service <service_cmd> <service_label> <out_array_name>
#
# `dokku <service_cmd>:list` prints a "=====> ... services" header line
# followed by one database name per line (no columns). Populates the
# named array (via nameref) with just the unlinked ones.
#
# On failure (e.g. the list command errors, or a remote host via
# run_dokku is unreachable), prints a message to fd 2, sets the output
# array empty, and returns non-zero -- it's up to the caller to decide
# how to surface that (an interactive caller can show its own dialog;
# a background/parallel caller, which must never pop a dialog itself,
# can just note the failure).
#
# Note: all progress output below is written to fd 2, not fd 1 -- fd 1
# is reserved for normal script output. Running a curses dialog (e.g.
# --infobox) here, immediately before a --menu dialog, has been
# observed to corrupt the menu's rendering (borders and buttons draw,
# but the list items do not) -- so this progress indicator deliberately
# uses plain terminal output instead of a curses widget.
scan_unlinked_service() {
  local svc_cmd="$1" svc_label="$2"
  local -n out_names="$3"

  local raw
  raw=$(run_dokku "${svc_cmd}:list" 2>&1) || raw=""

  # A host with zero services of this type doesn't print the usual
  # "=====> ... services" header at all -- just a single "There are no
  # ... services" line, with no header for `tail -n +2` to skip past.
  # That's a valid empty result, not a failure.
  if ! grep -q '^=====>' <<<"$raw" && ! grep -qi 'there are no' <<<"$raw"; then
    echo "Error: could not list $svc_label services:${raw:+ }$raw" >&2
    out_names=()
    return 1
  fi

  local all_names=()
  while IFS= read -r line; do
    line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$line")"
    [ -z "$line" ] && continue
    # dokku's own informational/warning lines (e.g. "!     You haven't
    # deployed any applications yet") start with "!" -- never a real
    # service name, but easy to mistake for one otherwise.
    [[ "$line" == "!"* ]] && continue
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
    printf '\rChecking for unlinked %s databases: [%-*s] %3d%% (%d/%d) %-30.30s\033[K' \
      "$svc_label" "$bar_width" "$bar" "$pct" "$count" "$total" "$name" >&2
    if [ -z "$(run_dokku "${svc_cmd}:links" "$name" 2>/dev/null)" ]; then
      unlinked+=("$name")
    fi
  done
  printf '\n' >&2

  out_names=("${unlinked[@]}")
  return 0
}

# destroy_unlinked_service <service_cmd> <service_label> <name>
#
# Echoes progress and returns non-zero if the destroy fails.
destroy_unlinked_service() {
  local svc_cmd="$1" svc_label="$2" name="$3"

  echo "Destroying $svc_label database '${name}'..."
  if run_dokku "${svc_cmd}:destroy" "$name" --force; then
    echo "'${name}' destroyed."
    return 0
  else
    echo "Failed to destroy '${name}'." >&2
    return 1
  fi
}

run_unlinked_db_menu() {
  local script_name="show-unlinked-${SERVICE_CMD}-dbs.sh"

  case "${1:-}" in
    -h|--help)
      cat <<EOF
$script_name

Interactively browse dokku $SERVICE_LABEL databases that have no app
links, and destroy a selected one after confirmation. Databases that
are linked to an app are never shown, since dokku refuses to destroy a
database that still has links.

The list is scanned once at startup. Select "[ Refresh List ]" (pinned
at the top of the list) to rescan on demand; destroying a database
updates the list in place without a full rescan.

Usage:
  $script_name [-h|--help]

  -h, --help   Show this help message and exit
EOF
      exit 0
      ;;
    "")
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $script_name [-h|--help]" >&2
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

  local REFRESH_LABEL="[ Refresh List ]"
  local db_names=()

  if ! scan_unlinked_service "$SERVICE_CMD" "$SERVICE_LABEL" db_names; then
    "$DIALOG_CMD" --title "Error" \
      --msgbox "Could not list $SERVICE_LABEL services. Scroll back in the terminal for details." 10 70
    exit 1
  fi

  # Which tag to highlight when the menu (re)opens. Defaults to keeping
  # the cursor on whatever was just selected; after a destroy, moved to
  # whatever now sits at that same position (typically the next item),
  # so working through a long list top-to-bottom doesn't mean scrolling
  # back to the top after every single destroy.
  local default_item="$REFRESH_LABEL"

  while true; do
    local menu_items=("$REFRESH_LABEL" "")
    for name in "${db_names[@]}"; do
      menu_items+=("$name" "")
    done

    local item_count=$(( ${#db_names[@]} + 1 ))
    local menu_height=$(( item_count < 15 ? item_count : 15 ))

    local term_lines box_height max_box_height
    term_lines=$(tput lines 2>/dev/null || echo 24)
    box_height=$(( menu_height + 11 ))
    max_box_height=$(( term_lines - 1 ))
    if [ "$box_height" -gt "$max_box_height" ]; then
      box_height=$max_box_height
      menu_height=$(( box_height - 11 ))
      [ "$menu_height" -lt 1 ] && menu_height=1
    fi

    local prompt="Up/Down arrows (or PageUp/PageDown) to scroll \nTab to move between fields\nPress Enter (or choose OK) to select a db to delete\nPress Escape (or choose Cancel) to exit"

    local choice
    if choice=$("$DIALOG_CMD" --clear \
        --backtitle "Show Unlinked $SERVICE_LABEL Databases" \
        --title "Select an Unlinked $SERVICE_LABEL Database to Destroy" \
        --menu "$prompt" \
        --default-item "$default_item" \
        "$box_height" 70 "$menu_height" \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3); then
      if [ "$choice" = "$REFRESH_LABEL" ]; then
        if ! scan_unlinked_service "$SERVICE_CMD" "$SERVICE_LABEL" db_names; then
          "$DIALOG_CMD" --title "Error" \
            --msgbox "Could not list $SERVICE_LABEL services. Scroll back in the terminal for details." 10 70
          exit 1
        fi
        default_item="$REFRESH_LABEL"
        continue
      fi
      default_item="$choice"
    else
      break
    fi

    local idx=-1
    for i in "${!db_names[@]}"; do
      [ "${db_names[$i]}" = "$choice" ] && idx=$i && break
    done

    if "$DIALOG_CMD" --clear \
        --title "Confirm Destroy" \
        --yesno "Are you SURE you want to permanently destroy the $SERVICE_LABEL database:\n\n  ${choice}\n\nThis action cannot be undone." 12 60; then
      clear
      if destroy_unlinked_service "$SERVICE_CMD" "$SERVICE_LABEL" "$choice"; then
        local remaining=()
        for name in "${db_names[@]}"; do
          [ "$name" != "$choice" ] && remaining+=("$name")
        done
        db_names=("${remaining[@]}")
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#db_names[@]}" ]; then
          default_item="${db_names[$idx]}"
        elif [ "${#db_names[@]}" -gt 0 ]; then
          default_item="${db_names[$((${#db_names[@]} - 1))]}"
        else
          default_item="$REFRESH_LABEL"
        fi
      fi
      read -r -p "Press Enter to continue..." _
    fi
  done

  echo "Done."
}

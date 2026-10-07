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
# By default, operates on this local machine. Pass -H/--host <hostname>
# to instead operate on a remote dokku host via passwordless ssh (see
# lib/dokku-hosts.sh's run_dokku, which every scan/destroy call already
# goes through) -- e.g. `clean-dokku.sh -H dokku-05.cs.ucsb.edu`.
#
# When -H/--host names a host that isn't in lib/dokku-hosts.sh's
# DOKKU_PROTECTED_HOSTS, the menu also gets a
# "[Destroy Everything on <host>]" entry -- see clean-all-dokkus.sh,
# which offers the same thing per-host; this is the single-host
# equivalent, gated the same way (a whiptail confirmation, then a
# second, typed-hostname confirmation at a plain terminal prompt).
#
# Always (local or -H/--host, protected or not), the menu also has a
# "[ Destroy Apps Matching Substring ]" entry: prompts for a substring,
# shows every app whose name contains it (plain, case-sensitive) in a
# checklist with all of them pre-checked, confirms, and then destroys
# each checked app exactly as selecting it individually would.
#
# Requires: whiptail or dialog. When run locally (no -H/--host), also
# requires dokku on this host; with -H/--host, this control host needs
# only passwordless SSH access to the target, not dokku itself.

set -euo pipefail

TARGET_HOST=""

while [ $# -gt 0 ]; do
  case "$1" in
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

By default, operates on this local machine. Pass -H/--host to instead
operate on a remote dokku host via passwordless ssh, in which case (if
the host isn't protected -- see lib/dokku-hosts.sh) the menu also
offers a "[Destroy Everything on <host>]" entry: destroys every app
and every remaining Postgres/Mongo database on that host, gated by a
whiptail confirmation followed by typing the host's exact name at a
plain terminal prompt.

"[ Destroy Apps Matching Substring ]" (always offered) prompts for a
substring, lists every app whose name contains it (plain, case-sensitive
match) in a checklist with all of them pre-checked, asks for
confirmation, and then destroys each checked app exactly as selecting
it individually would (including its own linked databases).

Usage:
  clean-dokku.sh [-H hostname | --host hostname] [-h|--help]

  -H, --host hostname   Operate on this host via ssh instead of locally
  -h, --help            Show this help message and exit
EOF
      exit 0
      ;;
    -H|--host)
      if [ -z "${2:-}" ]; then
        echo "Error: $1 requires a hostname argument." >&2
        echo "Usage: clean-dokku.sh [-H hostname | --host hostname] [-h|--help]" >&2
        exit 1
      fi
      TARGET_HOST="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: clean-dokku.sh [-H hostname | --host hostname] [-h|--help]" >&2
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

if [ -z "$TARGET_HOST" ] && ! command -v dokku >/dev/null 2>&1; then
  echo "Error: 'dokku' command not found on this host." >&2
  echo "  (Pass -H/--host <hostname> to operate on a remote host instead.)" >&2
  exit 1
fi

trap 'clear' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/show-unlinked-db-menu.sh"
source "$SCRIPT_DIR/lib/dokku-apps-scan.sh"

if [ -n "$TARGET_HOST" ]; then
  DOKKU_TARGET_HOST="$TARGET_HOST"
fi

REFRESH_LABEL="[ Refresh List ]"
SUBSTRING_LABEL="[ Destroy Apps Matching Substring ]"
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
  combo_tags=("$REFRESH_LABEL" "$SUBSTRING_LABEL")
  if [ -n "$TARGET_HOST" ] && ! is_protected_host "$TARGET_HOST"; then
    combo_tags+=("[Destroy Everything on $TARGET_HOST]")
  fi
  combo_tags+=("$PG_HEADER")
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

# Returns non-zero if any of the three scans failed (details already on
# fd 2 from the failing scan itself).
scan_all() {
  local ok=0
  scan_unlinked_service postgres Postgres pg_names || ok=1
  scan_unlinked_service mongo MongoDB mongo_names || ok=1
  scan_dokku_apps app_rows app_names || ok=1
  rebuild_combo
  return "$ok"
}

if ! scan_all; then
  "$DIALOG_CMD" --title "Error" \
    --msgbox "Could not complete the scan. Scroll back in the terminal for details." 10 70
  exit 1
fi

# Which tag to highlight when the menu (re)opens. Defaults to keeping
# the cursor on whatever was just selected; after a destroy, moved to
# whatever now sits at that same position in combo_tags (typically the
# next item), so working through a long list top-to-bottom doesn't
# mean scrolling back to the top after every single destroy.
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
      --backtitle "Clean Dokku (Postgres + Mongo + Apps) -- ${TARGET_HOST:-local machine}" \
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
      if ! scan_all; then
        "$DIALOG_CMD" --title "Error" \
          --msgbox "Could not complete the scan. Scroll back in the terminal for details." 10 70
        exit 1
      fi
      default_item="$REFRESH_LABEL"
      continue
      ;;
    "$PG_HEADER"|"$MONGO_HEADER"|"$APPS_HEADER")
      continue
      ;;
    "[Destroy Everything on "*"]")
      if "$DIALOG_CMD" --clear \
          --title "Confirm: Destroy EVERYTHING on $TARGET_HOST" \
          --yesno "Are you SURE you want to permanently destroy:\n\n  - ALL apps on $TARGET_HOST\n  - ALL unlinked Postgres databases on $TARGET_HOST\n  - ALL unlinked Mongo databases on $TARGET_HOST\n\n(Destroying an app also destroys its own linked databases.)\n\nThis action cannot be undone." 18 70; then
        clear
        echo "You are about to PERMANENTLY DESTROY EVERYTHING on:"
        echo
        echo "    $TARGET_HOST"
        echo
        echo "This means every app and every Postgres/Mongo database on that host."
        echo
        read -r -p "Type the host name exactly to confirm ($TARGET_HOST): " typed

        if [ "$typed" = "$TARGET_HOST" ]; then
          echo
          echo "Confirmed. Destroying everything on $TARGET_HOST..."

          # `|| true` on every call below: this whole sequence must keep
          # going even if one item fails, since under `set -e` a single
          # bare failing command here would otherwise silently abort
          # everything after it -- see DESIGN_NOTES.md (increment 5).
          wipe_app_rows=(); wipe_app_names=()
          scan_dokku_apps wipe_app_rows wipe_app_names || true

          for a in "${wipe_app_names[@]}"; do
            echo "Destroying app '$a'..."
            destroy_dokku_app "$a" || true
          done

          # Sweep for anything left over, *after* every app is gone --
          # see DESIGN_NOTES.md (increment 5) on why a one-time upfront
          # "unlinked" scan can miss a database that's shared by several
          # apps and only becomes unlinked partway through the loop above.
          echo
          echo "Destroying any remaining Postgres databases on $TARGET_HOST..."
          remaining_pg_all=$(run_dokku postgres:list 2>/dev/null | tail -n +2) || remaining_pg_all=""
          while IFS= read -r n; do
            [ -z "$n" ] && continue
            destroy_unlinked_service postgres Postgres "$n" || true
          done <<< "$remaining_pg_all"

          echo
          echo "Destroying any remaining Mongo databases on $TARGET_HOST..."
          remaining_mongo_all=$(run_dokku mongo:list 2>/dev/null | tail -n +2) || remaining_mongo_all=""
          while IFS= read -r n; do
            [ -z "$n" ] && continue
            destroy_unlinked_service mongo MongoDB "$n" || true
          done <<< "$remaining_mongo_all"

          echo
          echo "Running 'dokku cleanup --global' on $TARGET_HOST to free up resources..."
          run_dokku cleanup --global || true

          echo
          echo "Done destroying everything on $TARGET_HOST."

          pg_names=()
          mongo_names=()
          app_rows=()
          app_names=()
          rebuild_combo
          default_item="$REFRESH_LABEL"
        else
          echo "Confirmation did not match. Aborting; nothing was destroyed."
        fi
        read -r -p "Press Enter to continue..." _
      fi
      ;;
    "$SUBSTRING_LABEL")
      # Everything here works off the in-memory app_names/app_rows from
      # the last scan -- no dokku calls until the actual destroy.
      if ! substring=$("$DIALOG_CMD" --clear \
          --title "Destroy Apps Matching Substring" \
          --inputbox "Enter a substring. Every app whose name contains it (case-sensitive) will be listed for you to confirm before anything is destroyed.\n\nLeave blank or choose Cancel to go back." \
          12 70 \
          3>&1 1>&2 2>&3); then
        continue
      fi
      if [ -z "$substring" ]; then
        continue
      fi

      match_names=()
      match_rows=()
      for i in "${!app_names[@]}"; do
        if [[ "${app_names[$i]}" == *"$substring"* ]]; then
          match_names+=("${app_names[$i]}")
          match_rows+=("${app_rows[$i]}")
        fi
      done

      if [ "${#match_names[@]}" -eq 0 ]; then
        "$DIALOG_CMD" --clear --title "No Matches" \
          --msgbox "No apps contain the substring:\n\n  ${substring}\n\nNothing was destroyed." 11 60
        continue
      fi

      # Checklist: tag = bare app name (what we act on), item = that
      # app's P/M link markers from the main menu, so the row reads the
      # same way it does there. Every match starts checked; the user
      # can untick a stray hit before confirming.
      check_items=()
      for i in "${!match_names[@]}"; do
        check_items+=("${match_names[$i]}" "${match_rows[$i]:0:3}" on)
      done

      item_count=${#match_names[@]}
      menu_height=$(( item_count < 15 ? item_count : 15 ))
      term_lines=$(tput lines 2>/dev/null || echo 24)
      box_height=$(( menu_height + 11 ))
      max_box_height=$(( term_lines - 1 ))
      if [ "$box_height" -gt "$max_box_height" ]; then
        box_height=$max_box_height
        menu_height=$(( box_height - 11 ))
        [ "$menu_height" -lt 1 ] && menu_height=1
      fi

      check_prompt="${#match_names[@]} app(s) contain \"${substring}\" (columns: P M).\nSpace to untick/tick an app, Up/Down to move\nTab to move between fields\nPress Enter (or choose OK) to continue, Escape (or Cancel) to go back"

      if ! selected_raw=$("$DIALOG_CMD" --clear \
          --backtitle "Clean Dokku (Postgres + Mongo + Apps) -- ${TARGET_HOST:-local machine}" \
          --title "Apps Matching \"${substring}\"" \
          --separate-output \
          --checklist "$check_prompt" \
          "$box_height" 70 "$menu_height" \
          "${check_items[@]}" \
          3>&1 1>&2 2>&3); then
        continue
      fi

      selected_names=()
      while IFS= read -r n; do
        [ -z "$n" ] && continue
        selected_names+=("$n")
      done <<< "$selected_raw"

      if [ "${#selected_names[@]}" -eq 0 ]; then
        "$DIALOG_CMD" --clear --title "Nothing Selected" \
          --msgbox "No apps were left checked.\n\nNothing was destroyed." 9 60
        continue
      fi

      # The confirmation names every app when the list is short; past
      # that, the user has just seen (and ticked) the full list in the
      # checklist, so a count plus the first few is enough to keep the
      # yesno from overflowing its box.
      confirm_list=""
      shown=0
      for n in "${selected_names[@]}"; do
        if [ "$shown" -ge 10 ] && [ "${#selected_names[@]}" -gt 12 ]; then
          confirm_list+="  ... and $(( ${#selected_names[@]} - shown )) more (all shown in the checklist)\n"
          break
        fi
        confirm_list+="  $n\n"
        shown=$(( shown + 1 ))
      done
      confirm_lines=$(( shown < 12 ? shown : 12 ))
      [ "$shown" -lt "${#selected_names[@]}" ] && confirm_lines=$(( confirm_lines + 1 ))
      confirm_height=$(( confirm_lines + 11 ))
      [ "$confirm_height" -gt "$max_box_height" ] && confirm_height=$max_box_height

      if "$DIALOG_CMD" --clear \
          --title "Confirm: Destroy ${#selected_names[@]} App(s)" \
          --yesno "Are you SURE you want to permanently destroy these ${#selected_names[@]} app(s):\n\n${confirm_list}\nThis will also unlink and destroy any Postgres/Mongo databases linked only to each of these apps.\n\nThis action cannot be undone." \
          "$confirm_height" 70; then
        clear
        echo "Destroying ${#selected_names[@]} app(s) matching \"${substring}\"..."
        echo

        # One stubborn app must not abort the rest (see DESIGN_NOTES.md,
        # increment 5, on set -e) -- hence the if, not a bare call.
        destroyed_names=()
        for a in "${selected_names[@]}"; do
          echo "Destroying app '$a'..."
          if destroy_dokku_app "$a"; then
            destroyed_names+=("$a")
          fi
          echo
        done

        echo "Destroyed ${#destroyed_names[@]} of ${#selected_names[@]} app(s)."

        if [ "${#destroyed_names[@]}" -gt 0 ]; then
          new_rows=()
          new_names=()
          for i in "${!app_names[@]}"; do
            keep=1
            for d in "${destroyed_names[@]}"; do
              [ "${app_names[$i]}" = "$d" ] && keep=0 && break
            done
            if [ "$keep" -eq 1 ]; then
              new_rows+=("${app_rows[$i]}")
              new_names+=("${app_names[$i]}")
            fi
          done
          app_rows=("${new_rows[@]}")
          app_names=("${new_names[@]}")
          rebuild_combo
        fi
        default_item="$SUBSTRING_LABEL"
        read -r -p "Press Enter to continue..." _
      fi
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
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#combo_tags[@]}" ]; then
            default_item="${combo_tags[$idx]}"
          else
            default_item="${combo_tags[$((${#combo_tags[@]} - 1))]}"
          fi
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
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#combo_tags[@]}" ]; then
            default_item="${combo_tags[$idx]}"
          else
            default_item="${combo_tags[$((${#combo_tags[@]} - 1))]}"
          fi
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
          if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#combo_tags[@]}" ]; then
            default_item="${combo_tags[$idx]}"
          else
            default_item="${combo_tags[$((${#combo_tags[@]} - 1))]}"
          fi
        fi
        read -r -p "Press Enter to continue..." _
      fi
      ;;
  esac
done

echo "Done."

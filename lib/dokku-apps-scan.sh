#!/usr/bin/env bash
#
# lib/dokku-apps-scan.sh
#
# Shared logic for scanning all dokku apps together with how many
# Postgres/Mongo databases each is linked to, and for destroying an
# app (unlinking and destroying its own linked databases first). Used
# directly by clean-dokku-apps.sh, and by clean-dokku.sh as part of its
# combined view.
#
# Callers must set DIALOG_CMD before calling scan_dokku_apps (used to
# report a scan failure).

_dokku_apps_link_marker() {
  local count="$1"
  if [ "$count" -ge 2 ]; then
    echo '*'
  elif [ "$count" -eq 1 ]; then
    echo 'x'
  else
    echo ' '
  fi
}

# scan_dokku_apps <out_rows_array> <out_names_array>
#
# `dokku apps:list` prints a "=====> My Apps" header line followed by
# one app name per line (no columns). For each app, the Postgres/Mongo
# link counts come from `<type>:app-links <app>` (one linked service
# name per line, empty if none). Populates out_rows_array with
# "<P> <M> <appname>" display strings and out_names_array with the
# matching bare app names (same order/index).
#
# Note: all progress output below is written to fd 2, not fd 1 -- see
# lib/show-unlinked-db-menu.sh for why this avoids a curses --infobox
# immediately before a --menu dialog.
scan_dokku_apps() {
  local -n out_rows="$1"
  local -n out_names="$2"

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

  out_rows=()
  out_names=()

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
    pchar=$(_dokku_apps_link_marker "$pcount")
    mchar=$(_dokku_apps_link_marker "$mcount")

    out_rows+=("${pchar} ${mchar} ${app}")
    out_names+=("$app")
  done
  printf '\n' >&2
}

# destroy_dokku_app <app>
#
# Unlinks and destroys each Postgres/Mongo database linked to <app>
# (skipping, and reporting, any database that turns out to still be
# linked to another app), then destroys the app itself. Echoes
# progress and returns non-zero if the app itself could not be
# destroyed.
destroy_dokku_app() {
  local app="$1"

  local pg_links
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

  local mongo_links
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
    return 0
  else
    echo "Failed to destroy app '${app}'." >&2
    return 1
  fi
}

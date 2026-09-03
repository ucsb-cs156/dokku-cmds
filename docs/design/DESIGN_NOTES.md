# dokku-cmds Design Notes

This repo contains scripts that use a "curses" library based command line interface to perform various kinds of maintenance tasks on dokku hosts.

This script is optimized for the practices of the dokku hosts used in CMPSC 156 at UC Santa Barbara.

It may or may not work for your own installation of dokku, and we make no promises that it will work on other versions.

If you find it useful for your own installation, great.   If you have suggestions for how to make it more flexible, pull requests are welcome.

## First increment: show-unlinked-postgres-dbs.sh

This is intended to show unlinked postgres databases that are not currently being used, and give the option to destroy them, in order to tidy up the server and free up server resources.

The script only shows unlinked postgres services.

There is a confirmation modal that is shown before anything is destroyed.

### Design choices to carry forward to later increments

- **UI toolkit**: use `whiptail` if present, falling back to `dialog` (some hosts, like the CS department's `dokku-00`, only have `whiptail` installed and no `sudo` access to install `dialog`). Detect at startup with `command -v` and store the chosen command in a variable (e.g. `DIALOG_CMD`) used for every dialog call.
- **`whiptail` has no third/custom button.** Its `--menu` only supports OK/Cancel (unlike `dialog`, which has `--extra-button`). Any "extra action" (like a refresh) should be a specially-labeled entry pinned at the top of the list (e.g. `[ Refresh List ]`) rather than a real button. Compare the selected tag against the label string to detect it. `whiptail` also has no per-item coloring in a `--menu` — a distinct label (brackets, etc.) is the only way to make an entry stand out.
- **Only show destroyable items.** If an item can't actually be acted on (e.g. a linked postgres database, which `dokku postgres:destroy` refuses to delete), don't show it at all rather than showing it and letting the action fail. Keep the script's job narrowly scoped to "act on things this tool can act on."
- **Session-cache expensive scans.** Don't re-run a slow scan (e.g. checking every service for links) after every single action. Scan once at startup, and after a destructive action, update the in-memory list directly (e.g. remove the destroyed item) instead of rescanning. Provide a manual "Refresh List" entry (see above) for the user to force a rescan on demand, and assume state only changes through the script's own actions within a session otherwise.
- **Never run two curses dialogs back-to-back without user input in between** (e.g. an `--infobox` immediately followed by a `--menu`). This has been observed to corrupt the second dialog's rendering on a real terminal (borders/buttons draw, but list content does not) -- even though it can look fine when tested through `GNU screen`, which resets terminal state between calls and can mask the bug. For "please wait" / progress feedback during a scan, print plain text directly to fd 2 (not fd 1, which is reserved for a function's real return value) instead of using a curses widget.
- **Menu box height must leave room for the full prompt text.** `--menu`'s prompt area does not grow to fit an arbitrary number of `\n`-separated lines -- extra lines beyond whatever the box height implies get silently dropped. When changing the number of lines in a menu's instructional text, re-derive the height formula (empirically: roughly `menu_item_rows + 6 fixed rows + prompt_line_count + 1 buffer row`) rather than reusing a stale constant.
- **Clamp the dialog box height to the terminal size.** Compute the box height with `tput lines` (falling back to 24) and clamp it to `term_lines - 1`, reducing the menu's item-list height if needed. A box height that exactly equals the terminal height causes `whiptail` to draw borders/buttons but fail to render list items.
- **Confirmation modal wording**: a `--yesno` with the target name and "This action cannot be undone." before any destroy.
- **Standard instructional text** at the top of the menu (adjust the verb/object for the item type):
  ```
  Up/Down arrows (or PageUp/PageDown) to scroll
  Tab to move between fields
  Press Enter (or choose OK) to select a db to delete
  Press Escape (or choose Cancel) to exit
  ```

## Second increment: show-unlinked-mongo-dbs.sh

This should work the same as show-unlinked-postgres-dbs.sh but should work on mongo databases instead of postgres ones.

Since postgres and mongo services turned out to have functionally identical dokku commands (`<type>:list`, `<type>:links <service>`, `<type>:destroy <service> --force`, same "=====> ... services" list-header format), the common scan/menu/confirm/destroy logic was extracted into `lib/show-unlinked-db-menu.sh`, a single function `run_unlinked_db_menu` parameterized by two variables the caller sets before sourcing it:

- `SERVICE_CMD` -- the dokku command prefix (`postgres`, `mongo`)
- `SERVICE_LABEL` -- a human-readable name for dialog text (`Postgres`, `MongoDB`)

`show-unlinked-postgres-dbs.sh` and `show-unlinked-mongo-dbs.sh` are now thin wrappers: set those two variables, source the lib (resolving its path relative to the wrapper's own location via `BASH_SOURCE`), and call `run_unlinked_db_menu "$@"`. Any future bug fix or UI tweak (like the whiptail rendering quirks above) needs to land in the shared lib exactly once.

## Third increment: clean-dokku-apps.sh

This one is a bit more complex.

This one should show all applications.

There should be two columns before the application name, with one space between the columns.

The first column is labelled P for Postgres. The second column is labelled M for Mongo.

If the app is linked to exactly one Postgres database, show an x in the P column.  If two or more, show a * in the P column.

Do the same for links to Mongo databases.

Then, allow the user to select an app to destroy it.

There should be a confirmation modal.

If destroy is selected, the app should first unlink all linked databases and destroy them separately,and then destroy the app.

### Implementation notes

- **Row format**: each menu row is the literal string `"<P> <M> <appname>"` (P char, space, M char, space, app name) used directly as the whiptail tag -- there's no separate "item" field, matching the pattern from increments 1/2. A decorative, non-selectable-looking header row `"P M App Name"` is pinned above `[ Refresh List ]` to label the columns, since `whiptail --menu` has no real column-header support; selecting it is a harmless no-op (`continue`s the loop). `--default-item` is set to the Refresh label so the initial highlight skips past the inert header.
- **Link counts**: `dokku <type>:app-links <app>` (not `<type>:links <service>`) gives the reverse mapping -- the services linked to a given app. One dokku call per type per app (2 calls/app total), so scanning is roughly 2x the cost of increments 1/2's per-service scan; still fast enough for ~60 apps (well under 20s) with the same plain-text progress bar.
- **Shared database, unlink-then-destroy**: a database can be linked to more than one app. Per-app destroy logic unlinks each linked db from the app being destroyed, then attempts `<type>:destroy`; if dokku refuses because the db is still linked elsewhere, that's reported and the db is left alone rather than aborting the whole operation. If the unlink itself fails, the db is left alone (destroy is only attempted after a successful unlink).
- **`dokku apps:destroy <app> --force` prints a lot of unrelated-looking "Unlinking from X" lines** for other apps/services during its own internal Docker network teardown (disconnecting other containers from a shared bridge network). This is normal dokku output, not a sign that other apps' real database links were touched -- verified directly (`<type>:app-links` on unrelated apps) that only the destroyed app and its own linked databases were affected.
- This script was **not** folded into `lib/show-unlinked-db-menu.sh` -- the row shape (composite P/M/name display) and destroy logic (cascading unlink+destroy across two service types, plus an app) are different enough from the single-service-name case that forcing a shared abstraction would have hurt clarity more than the duplication it would have saved.


# Fourth increment: clean-dokku.sh

This app should integrate the three earlier ones.

It should start with a [Refresh List] as before.

Then, it should show all of the unlinked postgres dbs in one section that starts with a header [Unlinked Postgres Dbs]
(the header itself does nothing if selected)
followed by a section that starts with a header [Unlinked Mongo Dbs], followed by a header [All Dokku Apps].

### Implementation notes

- **Row-tag collision, resolved by construction rather than lookup.** whiptail's `--menu` only ever returns the selected tag's *text* -- if a Postgres db and a Mongo db ever had the identical bare name (independent namespaces, so nothing prevents it), a naive same-text lookup couldn't tell which one was actually highlighted when Enter was pressed, no matter how carefully a separate (type, name) table were maintained on the side. Fixed at the source instead: Postgres/Mongo db rows are tagged `"P <name>"` / `"M <name>"`, reusing the P/M vocabulary from increment 3's app table. App rows can never collide with these, since their own P/M columns only ever hold a space, `x`, or `*` -- never the literal letter P or M. This made a separate lookup table unnecessary; dispatch is a `case` on the tag's prefix (`"P "*`, `"M "*`, else -> app row), mirroring how increment 3 already parsed its `"${choice:4}"` app-name suffix.
- **Scan/destroy logic reused via extraction, not duplication.** `lib/show-unlinked-db-menu.sh` now exposes `scan_unlinked_service <cmd> <label> <out_array>` and `destroy_unlinked_service <cmd> <label> <name>` as standalone functions (using bash nameref, i.e. `local -n`, for the output array parameter); `run_unlinked_db_menu` (used by the two `show-unlinked-*-dbs.sh` wrapper scripts) calls them internally, unchanged in behavior. Likewise, `clean-dokku-apps.sh`'s scan/destroy logic moved into a new `lib/dokku-apps-scan.sh` (`scan_dokku_apps`, `destroy_dokku_app`), with `clean-dokku-apps.sh` itself now just sourcing it. `clean-dokku.sh` sources both libs and calls all three scan/destroy functions directly -- no logic is duplicated a third time, and all four scripts were regression-tested after the extraction.
- **Combined startup scan** (postgres + mongo + apps) takes roughly the sum of the three individual scans (~30-40s measured, depending on current data volume) -- acceptable as a one-time, cached cost. Each phase prints its own progress bar in sequence to fd 2, so it never looks stalled.
- **Cache updates stay local per destroy.** Each of the three sections keeps its own underlying array (`pg_names`, `mongo_names`, `app_rows`/`app_names`), refreshed only by `scan_all` (startup or `[ Refresh List ]`). A single destroy updates only the affected section's array, then calls a cheap in-memory `rebuild_combo` (no dokku calls) to regenerate the flat tag list -- verified only one scan of each type occurs across a full select-destroy-select-destroy session.
- Verified end-to-end on dokku-00: all three section headers and both db-row prefixes render correctly (including via a real create/destroy round trip for a throwaway Postgres db and a throwaway Mongo db), the inert header rows are confirmed to no-op when selected, and `--default-item` keeps the initial highlight on `[ Refresh List ]` despite the header sitting above it.

# Fifth increment: clean-all-dokkus.sh

This one should be run on a host that has ssh access to all dokkus, which are 

dokku-00.cs.ucsb.edu
dokku-01.cs.ucsb.edu
etc. ending with
dokku-18.cs.ucsb.edu

The starting and stopping dokkus should be a constant in the lib code that can be modified, and is very prominent at the top of the file.  It should be in the lib since we'll have other commands that will go across multiple dokkus.

This app works exactly like clean-dokku.sh, except that we now have a header 
[dokku-00.cs.ucsb.edu]
(all of the output for dokku-00,i.e. all three sections).
[dokku-01.cs.ucsb.edu]
(all of the output for al three sections)
etc.

### Planning notes

- **Assumes passwordless SSH access** is already configured from the host running this script to every `dokku-00`..`dokku-18` host. Not something the script needs to set up or check for beyond a clear error if a connection fails.
- **Per-host scans run in parallel** (background jobs + `wait`), not sequentially, as long as that doesn't add significant complexity. Sequential (worst case ~10 minutes for 19 hosts, each taking as long as increment 4's combined scan) is an acceptable fallback given this tool is run infrequently -- parallelization is a nice-to-have speedup, not a hard requirement gating the increment.
- `lib/dokku-hosts.sh` holds the host range as a prominent constant, plus a small `run_on_host <host> <dokku-command...>` helper that either execs locally or wraps in `ssh` -- shared with `clean-dokku.sh`'s local-only logic and reused again by `dokku-disk-space.sh` (increment 6).
- Per-row bookkeeping extends from (type, name) to (host, type, name) triples, so a destroy action targets the right host.

# Sixth increment: dokku-disk-space.sh

This script is intended to be run on a host with ssh access to all of the dokkus.

It should ssh into each of the dokkus and run `df`

It should then report any dokkus that have any mounted disk that has more then THRESHOLD used space, where THRESHOLD is 80% by default, but may be specified with a command line parameter, i.e.  --threshold=90

It should also have a --help flag that does the usual thing (explain syntax and purpose)

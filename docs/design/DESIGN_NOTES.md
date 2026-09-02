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


# Sixth increment: dokku-disk-space.sh

This script is intended to be run on a host with ssh access to all of the dokkus.

It should ssh into each of the dokkus and run `df`

It should then report any dokkus that have any di

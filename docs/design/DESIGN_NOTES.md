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
- **Preserve cursor position across a destroy, via `--default-item`.** Without it, `--menu` always highlights the first item, so working through a long list top-to-bottom means scrolling back down after every single destroy -- painful even for one host, and a real problem across `clean-all-dokkus.sh`'s 19-host list. Track the selected tag's index in the *current* list before acting on it; after a destroy, once the list is rebuilt, set `--default-item` to whatever tag now sits at that same index (the item that was originally *after* the deleted one, since everything shifts up by one) -- clamping to the last item if the deleted one was last, or to `[ Refresh List ]` if the list is now empty. When nothing was destroyed (a header was selected, or the confirmation was cancelled), just default to the tag that was already selected, so the cursor doesn't move at all. Applied to all four interactive scripts (`run_unlinked_db_menu`, `clean-dokku-apps.sh`, `clean-dokku.sh`, `clean-all-dokkus.sh`) for consistency, even though only the last one was reported as a real pain point.

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

### Implementation notes

- **`lib/dokku-hosts.sh`** holds `DOKKU_HOST_FIRST`/`DOKKU_HOST_LAST`/`DOKKU_HOST_PREFIX`/`DOKKU_HOST_SUFFIX` as the prominent, editable constant at the top of the file, a `dokku_host_list` generator, and `run_dokku [args...]` -- runs `dokku "$@"` locally, or via `ssh $DOKKU_TARGET_HOST dokku "$@"` if that variable is set. `lib/show-unlinked-db-menu.sh` and `lib/dokku-apps-scan.sh` were changed to call `run_dokku` instead of `dokku` directly (and to source this lib), so the *exact same* scan/destroy functions used by the single-host scripts work unmodified against a remote host -- no fourth copy of the scanning logic was needed. All four existing scripts were regression-tested after this change, since it touches code they all share.
- **Error handling changed from "pop a dialog and exit" to "return non-zero," moved to the caller.** `scan_unlinked_service` and `scan_dokku_apps` used to show a `--msgbox` and hard-`exit` themselves on failure. That's not safe to call from a background job (a curses dialog popping up from a process that doesn't own the foreground terminal would corrupt or hang the display), which parallel host-scanning needs to do. Both functions now just print to fd 2 and `return 1`; every *interactive* caller (the two `show-unlinked-*-dbs.sh` scripts via `run_unlinked_db_menu`, `clean-dokku-apps.sh`, `clean-dokku.sh`) was updated to check the return value and show its own dialog, preserving the exact previous UX. `clean-all-dokkus.sh`'s background workers just check the return value and write an `UNREACHABLE` marker instead.
- **Per-host scans run in parallel**: one background job per host (`_scan_one_host_to_file`), each writing its results to a temp file (with its own fd 2 discarded, since 19 interleaved progress bars would be unreadable anyway), followed by a single `wait` and then a sequential, ordered read-back of each host's file. This is the simplest correct pattern for "fan out N independent shell tasks, then collect results" -- no shared memory or locking needed, since each background job is its own process. Measured **~73 seconds** for all 19 hosts combined, versus an estimated ~11-13 minutes running the same scans sequentially (extrapolated from increment 4's ~30-40s single-host scan) -- roughly a 9-10x speedup from an implementation that stayed simple.
- **Live "N of 19 complete" feedback while waiting**, since a single static "please wait" message for a 70+ second stretch is easy to mistake for a hang. Each background job writes its result to `<hostnum>.tmp` and only `mv`s it to the final `<hostnum>` filename once fully written -- a plain `> file` redirect creates the (empty) file the instant the job *starts*, well before it's done, so counting files without this write-then-rename would immediately show all 19 "complete." The main process polls (`find ... ! -name '*.tmp'`, once a second) and redraws a plain-text progress bar with a live count and elapsed seconds, in the same fd-2, non-curses style as every other scan in this repo.
- **Row-tag collision, one layer deeper than increment 4.** Increment 4 disambiguated Postgres vs. Mongo rows with a `P `/`M ` prefix, reasoning that whiptail only ever returns the selected tag's *text*, so any two rows with identical tags are indistinguishable to the caller regardless of what's tracked on the side. With 19 independent dokku installations, the same database or app name plausibly exists on more than one host (unlike the single-host Postgres-vs-Mongo case, this is a likely occurrence, not just a theoretical one) -- so every row additionally carries a 2-digit host-number prefix: `"<NN> P <name>"`, `"<NN> M <name>"`, `"<NN> <P> <M> <appname>"`. Bracketed headers (`[dokku-NN.cs.ucsb.edu]` and the three repeated per-host sub-headers) don't need this, since selecting any header is a no-op regardless of which one was actually picked -- only rows that trigger a real action need a globally-unique tag. Dispatch is a `case` on the tag: exact match on `[ Refresh List ]` first, then a generic `\[*\]` glob for any header, then `[0-9][0-9]" P "*` / `[0-9][0-9]" M "*`, then everything else is an app row -- extending the same prefix-parsing approach from increment 4 rather than introducing a new mechanism.
- **Flat, host-prefixed arrays instead of one array per host.** `pg_rows`/`mongo_rows`/`app_rows` each hold entries from *all* 19 hosts together (the host number is baked into the row text), and `rebuild_combo` groups them back into per-host sections by filtering on the `"NN "` prefix. This keeps the destroy-time cache update identical in shape to increment 4's (`grep`-and-remove the one destroyed row from the flat array, then `rebuild_combo` -- no dokku calls) rather than needing 19 parallel per-host array sets.
- Verified end-to-end on dokku-00 (which has direct passwordless SSH to all other `dokku-NN` hosts, confirmed before building this): all 19 hosts scanned and rendered correctly, and a real create/destroy round trip against a throwaway Postgres database on **dokku-01** (deliberately not dokku-00) confirmed the row appeared correctly host-prefixed, the confirm dialog named the correct remote host, the destroy actually happened there (independently verified against dokku-01 directly, and confirmed dokku-00 never had it), the local cache updated without a second scan, and no orphaned processes or temp directories were left behind.

### "Destroy Everything on \<host\>" (student-host wipe)

dokku-00 hosts production services and staff QA deployments; dokku-01..dokku-18 are student team hosts that turn over several times a year. Every host *except* dokku-00 (hardcoded as `PROD_HOSTNUM="00"`, not derived from `DOKKU_HOST_FIRST` -- this is about the specific prod host, not "whichever host happens to be first") gets a `"[Destroy Everything on <host>]"` entry right after its own `"[<host>]"` header: destroys every app on that host (cascading into each app's own linked databases) plus any database left over, for clearing a host between team turnovers without visiting each item one at a time.

Given the blast radius, this needs to be much harder to trigger by accident than a single-item destroy:
- A whiptail `--yesno` first, same as any other destroy.
- Then a **second, typed confirmation at a plain terminal prompt** -- the user must type the host's exact name (e.g. `dokku-05.cs.ucsb.edu`), not just press Enter/Y again. A mismatch aborts with nothing touched. This is deliberately a different *kind* of input than the whiptail dialog, not just a repeat of it, so a reflexive double-Enter can't trigger it.
- Only reachable, non-prod hosts get the entry at all (an `UNREACHABLE` host's section is skipped entirely in `rebuild_combo`, so there's nothing to select).

**Two real bugs surfaced during live testing on dokku-01** (15 apps, ~29 databases, wiped for real with the user's explicit go-ahead after confirming they were disposable):

- **A one-time-upfront destroy list misses databases freed up mid-run.** The first implementation scanned for *unlinked* Postgres/Mongo databases once, before touching any apps, then destroyed apps, then destroyed just that pre-computed list. A database shared by several apps only becomes unlinked once the *last* of them is destroyed -- if that happens after the initial scan, it's never revisited. (One mongo database was left behind this way in testing.) Fixed by restructuring: destroy every app *first*, then list (not scan-for-unlinked -- just `list`) whatever Postgres/Mongo databases still exist on that host. Once every app is gone, anything left is unlinked by definition, so no per-item link check is even needed for this second pass.
- **`set -e` turns "one item failed" into "everything after it silently never ran."** Confirmed with a 3-line local repro: a bare (non-`if`-guarded) function call that returns non-zero inside a `for` loop, under `set -e`, aborts the whole script right there -- including, in this case, the cache-array bookkeeping at the end of the destroy branch, which would have left the in-memory list stale after a partial failure. Every destroy call in this bulk sequence now ends in `|| true` so one stubborn item can't derail the rest (each one's own success/failure is still echoed).
- **`dokku <type>:list` doesn't always print the `"=====> ..."` header.** A host with *zero* services of a given type prints a one-line `"!     There are no Postgres services"`-style message instead -- discovered when dokku-01 reached that state mid-test and got incorrectly flagged `UNREACHABLE` (the header-presence check was being used as the sole scan-succeeded signal). Worse, `apps:list` with zero apps *does* still print its header, but followed by a `"!  You haven't deployed any applications yet"` line that the existing parser would have added as a literal (fake, later "destroyable") app. Fixed in both `scan_unlinked_service` and `scan_dokku_apps`: an empty-result message (`grep -qi 'there are no'`) is now accepted as success alongside the header, and any line starting with `!` is filtered out as a dokku informational/warning line rather than treated as data. This was latent in every script sharing these functions, not just this one -- it just took a host reaching truly zero services to surface it.
- **`dokku cleanup --global` runs at the end**, per user request, to free up disk/container resources left behind by the wipe (also guarded with `|| true`).

# Sixth increment: dokku-disk-space.sh

This script is intended to be run on a host with ssh access to all of the dokkus.

It should ssh into each of the dokkus and run `df`

It should then report any dokkus that have any mounted disk that has more then THRESHOLD used space, where THRESHOLD is 80% by default, but may be specified with a command line parameter, i.e.  --threshold=90

It should also have a --help flag that does the usual thing (explain syntax and purpose)

### Implementation notes

- **Not interactive.** Unlike every prior increment, this is a plain report -- no `whiptail`/`dialog` dependency, no curses at all. It reuses only `lib/dokku-hosts.sh`'s host-range constants (not `run_dokku`, since `df` isn't a dokku command); the control host doesn't need `dokku` installed locally either.
- **`df -PT`, not `df`.** `-P` forces POSIX single-line-per-filesystem output (a plain `df` can wrap onto a second line for long filesystem names, which broke naive column-based parsing); `-T` adds the filesystem-type column, needed to tell local disks apart from network mounts (see below). Confirmed both flags work identically across hosts before writing any parsing code.
- **Parallel `df` over ssh**, same one-job-per-host-with-a-temp-file pattern as `clean-all-dokkus.sh`'s scans (including the same write-then-rename-into-place trick), since sequential ssh round-trip latency to 19 hosts adds up. No live progress bar, unlike the other increments -- `df` itself is near-instant, so the whole scan finishes in a few seconds and a bar would just flicker.
- **Local vs. shared filesystems, reported differently, per user feedback.** Every dokku host mounts the same department-wide NFS home directories (`/fs/class`, `/fs/faculty`, ...) identically. The first version reported every filesystem per host, which meant a single shared mount at 72% used showed up 19 times, identically, burying the handful of results that were actually specific to one host. When asked whether to just filter shared mounts out entirely, the user's answer was no -- full shared storage impairs every dokku host at once, so it's absolutely worth reporting, but the *fix* for it is never "clean up this one dokku host" the way a local filesystem's would be, so it deserves reporting as a distinct, deduplicated "systemwide" category rather than being silently dropped **or** repeated 19 times. Filesystem type (`nfs`/`nfs3`/`nfs4`/`cifs`/`smb`/`smbfs`/`afs`) is the split: local/virtual types (`zfs`, `ext4`, `xfs`, `tmpfs`, `overlay`, ...) are reported per host as before; network types are deduplicated by filesystem source into one "Shared Filesystems" section (keeping the highest percentage observed for each, sorted worst-first), explicitly labeled as a systemwide problem rather than a dokku-host problem.
- **A `read` field-splitting bug that also would have affected any future script written the same way**: `while IFS= read -r a b c; do ... done` -- setting `IFS=` empty for a *multi-variable* `read` disables field-splitting entirely, so the whole line lands in the first variable and the rest stay empty. (`IFS= read -r line` for a *single* variable, used elsewhere in this repo, is correct and different -- there it deliberately preserves leading/trailing whitespace on that one field.) Caught because the very first test run silently reported zero results even against a host already known to have filesystems above the test threshold. Fixed by dropping the `IFS=` override for the three/four-variable reads in this script, letting default whitespace splitting do its job.
- Verified end-to-end on all 19 real hosts: default 80% threshold currently shows a clean "nothing to report," `--threshold=50` correctly surfaces both a deduplicated 7-entry "Shared Filesystems" section (instead of 19 x 7 = 133 repeated lines) and a handful of legitimately host-specific local-disk entries, and the exit code (0/1/2) reflects local, shared, and unreachable-host outcomes correctly.
- **"Highest usage seen" when nothing crosses the threshold.** The per-filesystem loop tracks a running max (percentage, mount, source, and -- for local filesystems -- which host) across *every* row it parses, independent of the threshold check. When the report has nothing to flag, it prints that running max as a single "Highest usage seen: NN% on ..." line, so a clean run still says how close the closest filesystem came rather than just "everything's fine" with no sense of margin. Only shown in the nothing-exceeded case, per the user's request, and only if at least one filesystem was actually observed (guards against claiming "nothing exceeded" when every host was unreachable and no data was gathered at all).

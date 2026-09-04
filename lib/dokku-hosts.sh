#!/usr/bin/env bash
#
# lib/dokku-hosts.sh
#
# The range of dokku hosts that multi-host scripts (clean-all-dokkus.sh,
# dokku-disk-space.sh, ...) operate across, plus a small helper for
# running a command on one of them (or locally) transparently.
#
# ---------------------------------------------------------------------
# EDIT THESE to change which hosts multi-host scripts operate across:
DOKKU_HOST_FIRST=0
DOKKU_HOST_LAST=18
DOKKU_HOST_PREFIX="dokku-"
DOKKU_HOST_SUFFIX=".cs.ucsb.edu"
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# EDIT THIS to change which hosts are "protected" -- i.e. never offered
# a "[Destroy Everything on <host>]" option (see clean-all-dokkus.sh and
# clean-dokku.sh's -H/--host), typically because they run production
# and/or shared staff services rather than disposable, turned-over
# student-team deployments. One hostname per line.
DOKKU_PROTECTED_HOSTS=$(cat <<'EOF'
dokku-00.cs.ucsb.edu
EOF
)
# ---------------------------------------------------------------------

# dokku_host_list
#
# Prints each host (dokku-00.cs.ucsb.edu ... dokku-18.cs.ucsb.edu, per
# the range above) on its own line.
dokku_host_list() {
  local i
  for ((i = DOKKU_HOST_FIRST; i <= DOKKU_HOST_LAST; i++)); do
    printf '%s%02d%s\n' "$DOKKU_HOST_PREFIX" "$i" "$DOKKU_HOST_SUFFIX"
  done
}

# is_protected_host <hostname>
#
# Returns success (0) if <hostname> is listed in DOKKU_PROTECTED_HOSTS
# above (exact match), failure (1) otherwise.
is_protected_host() {
  grep -qxF "$1" <<< "$DOKKU_PROTECTED_HOSTS"
}

# run_dokku [args...]
#
# Runs `dokku <args...>`, either locally, or (if DOKKU_TARGET_HOST is
# set and non-empty) on that host via passwordless ssh. Every dokku
# invocation in lib/show-unlinked-db-menu.sh and lib/dokku-apps-scan.sh
# goes through this, so those scan/destroy functions work unmodified
# for both a single local host and a remote one.
#
# `-n` (redirect ssh's own stdin from /dev/null) is essential here, not
# optional: several callers invoke run_dokku from inside a
# `while read -r x; do ... done <<< "$data"` loop (e.g. destroy_dokku_app
# unlinking/destroying more than one linked database for a single app,
# or a "destroy everything on this host" sweep over more than one
# leftover database). Without -n, ssh inherits that loop's stdin (the
# here-string) and reads from it, silently starving the `while read`
# of everything after the first line -- the loop still exits with
# status 0, so this fails silently: only the first item in any such
# list gets processed and the rest are quietly skipped. None of the
# dokku commands here need interactive stdin, so detaching it is always
# safe.
run_dokku() {
  if [ -n "${DOKKU_TARGET_HOST:-}" ]; then
    ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$DOKKU_TARGET_HOST" dokku "$@"
  else
    dokku "$@"
  fi
}

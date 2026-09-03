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

# run_dokku [args...]
#
# Runs `dokku <args...>`, either locally, or (if DOKKU_TARGET_HOST is
# set and non-empty) on that host via passwordless ssh. Every dokku
# invocation in lib/show-unlinked-db-menu.sh and lib/dokku-apps-scan.sh
# goes through this, so those scan/destroy functions work unmodified
# for both a single local host and a remote one.
run_dokku() {
  if [ -n "${DOKKU_TARGET_HOST:-}" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$DOKKU_TARGET_HOST" dokku "$@"
  else
    dokku "$@"
  fi
}

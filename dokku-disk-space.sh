#!/usr/bin/env bash
#
# dokku-disk-space.sh
#
# Checks disk usage across every dokku host configured in
# lib/dokku-hosts.sh: ssh's into each one, runs `df -PT` (POSIX output
# format, so long filesystem/mount names never wrap onto a second
# line, plus the filesystem type column), and reports any mounted
# filesystem more than THRESHOLD% used (default 80, overridable with
# --threshold=NN).
#
# Network-mounted filesystems (nfs/nfs3/nfs4/cifs/smb/smbfs/afs -- the
# department's shared /fs/* home directories, mounted identically on
# every dokku host) are reported once in their own "Shared Filesystems"
# section rather than once per host: they're genuinely worth flagging
# (full shared storage can impair every dokku host at once), but their
# fix is never "clean up this one dokku host" the way a local
# filesystem's would be, and repeating the same handful of NFS mounts
# 19 times over would bury the local, per-host, actually actionable
# results. Local/virtual filesystems (anything else -- zfs, ext4, xfs,
# tmpfs, overlay, ...) are still reported per host as before.
#
# Not an interactive/curses tool -- just a report. Must be run from a
# host with passwordless SSH access to every host in that list (this
# control host does not need dokku installed locally; only `df` is run
# on the remote end).
#
# Per-host `df` calls run in parallel (one background ssh per host),
# same pattern as clean-all-dokkus.sh's scans, since ssh round-trip
# latency to 19 hosts adds up if done sequentially.
#
# Exit status: 0 if no filesystem (local or shared) is more than the
# threshold, 1 if at least one is, 2 if any host could not be reached.

set -euo pipefail

THRESHOLD=80

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
dokku-disk-space.sh

Checks disk usage across every dokku host configured in
lib/dokku-hosts.sh: ssh's into each one, runs `df -PT`, and reports
any mounted filesystem more than a threshold percent used (default
80%). Network-mounted filesystems (shared across every host) are
reported once in their own section rather than once per host.

Must be run from a host with passwordless SSH access to every one of
those hosts.

Usage:
  dokku-disk-space.sh [--threshold=NN] [-h|--help]

  --threshold=NN   Report filesystems more than NN% used (default 80)
  -h, --help       Show this help message and exit

Exit status:
  0   no filesystem (local or shared) is more than the threshold
  1   at least one filesystem is more than the threshold
  2   at least one host could not be reached
EOF
    exit 0
    ;;
  --threshold=*)
    THRESHOLD="${1#--threshold=}"
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    echo "Usage: dokku-disk-space.sh [--threshold=NN] [-h|--help]" >&2
    exit 1
    ;;
esac

if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [ "$THRESHOLD" -lt 0 ] || [ "$THRESHOLD" -gt 100 ]; then
  echo "Error: --threshold must be an integer from 0 to 100 (got '$THRESHOLD')." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/dokku-hosts.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

host_count=$(( DOKKU_HOST_LAST - DOKKU_HOST_FIRST + 1 ))
echo "Checking disk usage on $host_count dokku hosts (threshold: ${THRESHOLD}%)..."

for ((i = DOKKU_HOST_FIRST; i <= DOKKU_HOST_LAST; i++)); do
  hostnum=$(printf '%02d' "$i")
  host="${DOKKU_HOST_PREFIX}${hostnum}${DOKKU_HOST_SUFFIX}"
  (
    if out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" df -PT 2>&1); then
      printf '%s\n' "$out" > "$tmpdir/$hostnum.tmp"
    else
      echo "UNREACHABLE" > "$tmpdir/$hostnum.tmp"
    fi
    # Renamed into place only once fully written, matching
    # clean-all-dokkus.sh's pattern -- lets the caller tell "not done
    # yet" apart from "done" if it ever needs to poll for progress.
    mv "$tmpdir/$hostnum.tmp" "$tmpdir/$hostnum"
  ) &
done
wait

NETWORK_FS_TYPES='^(nfs|nfs3|nfs4|cifs|smb|smbfs|afs)$'

unreachable_hosts=()
offending_hosts=()
declare -A offending_lines=()
declare -A shared_pct=()
declare -A shared_mnt=()
overall_max_pct=-1
overall_max_info=""

for ((i = DOKKU_HOST_FIRST; i <= DOKKU_HOST_LAST; i++)); do
  hostnum=$(printf '%02d' "$i")
  host="${DOKKU_HOST_PREFIX}${hostnum}${DOKKU_HOST_SUFFIX}"
  outfile="$tmpdir/$hostnum"

  if [ ! -f "$outfile" ] || grep -q '^UNREACHABLE$' "$outfile"; then
    unreachable_hosts+=("$host")
    continue
  fi

  lines=""
  while read -r fs fstype pct mnt; do
    [ -z "$fs" ] && continue
    pct_num="${pct%\%}"
    [[ "$pct_num" =~ ^[0-9]+$ ]] || continue

    # Tracked for every filesystem seen, regardless of the threshold,
    # so that when nothing crosses it, the report can still say how
    # close the closest one came.
    if [ "$pct_num" -gt "$overall_max_pct" ]; then
      overall_max_pct="$pct_num"
      if [[ "$fstype" =~ $NETWORK_FS_TYPES ]]; then
        overall_max_info="${pct} on ${mnt} (${fs}, shared)"
      else
        overall_max_info="${pct} on ${mnt} (${fs} on ${host})"
      fi
    fi

    [ "$pct_num" -gt "$THRESHOLD" ] || continue

    if [[ "$fstype" =~ $NETWORK_FS_TYPES ]]; then
      # Shared across every host that mounts it -- record once,
      # keeping the highest percentage seen for it, rather than
      # repeating the same handful of NFS mounts under every host.
      if [ -z "${shared_pct[$fs]:-}" ] || [ "$pct_num" -gt "${shared_pct[$fs]}" ]; then
        shared_pct["$fs"]="$pct_num"
        shared_mnt["$fs"]="$mnt"
      fi
    else
      lines+="  ${pct}	${mnt}	(${fs})"$'\n'
    fi
  done < <(tail -n +2 "$outfile" | awk '{print $1, $2, $6, $7}')

  if [ -n "$lines" ]; then
    offending_hosts+=("$host")
    offending_lines["$host"]="$lines"
  fi
done

echo

if [ "${#offending_hosts[@]}" -eq 0 ] && [ "${#shared_pct[@]}" -eq 0 ]; then
  echo "No filesystem (local or shared) is more than ${THRESHOLD}% used."
  if [ "$overall_max_pct" -ge 0 ]; then
    echo "Highest usage seen: ${overall_max_info}"
  fi
fi

if [ "${#shared_pct[@]}" -gt 0 ]; then
  echo "Shared filesystems more than ${THRESHOLD}% used (mounted on every dokku host --"
  echo "this is a systemwide storage problem, not specific to any one dokku host):"
  echo
  for fs in "${!shared_pct[@]}"; do
    printf '  %s%%\t%s\t(%s)\n' "${shared_pct[$fs]}" "${shared_mnt[$fs]}" "$fs"
  done | sort -rn -k1 | column -t
  echo
fi

if [ "${#offending_hosts[@]}" -gt 0 ]; then
  echo "Hosts with a local filesystem more than ${THRESHOLD}% used:"
  echo
  for host in "${offending_hosts[@]}"; do
    echo "$host"
    printf '%s' "${offending_lines[$host]}" | column -t
    echo
  done
fi

if [ "${#unreachable_hosts[@]}" -gt 0 ]; then
  echo "Could not reach:"
  for host in "${unreachable_hosts[@]}"; do
    echo "  $host"
  done
  echo
fi

if [ "${#unreachable_hosts[@]}" -gt 0 ]; then
  exit 2
elif [ "${#offending_hosts[@]}" -gt 0 ] || [ "${#shared_pct[@]}" -gt 0 ]; then
  exit 1
else
  exit 0
fi

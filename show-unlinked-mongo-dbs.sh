#!/usr/bin/env bash
#
# show-unlinked-mongo-dbs.sh
#
# Interactively browse dokku mongo databases that have no app links,
# and destroy a selected one after confirmation. See
# lib/show-unlinked-db-menu.sh for the shared implementation (also used
# by show-unlinked-postgres-dbs.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_CMD="mongo"
SERVICE_LABEL="MongoDB"
source "$SCRIPT_DIR/lib/show-unlinked-db-menu.sh"

run_unlinked_db_menu "$@"

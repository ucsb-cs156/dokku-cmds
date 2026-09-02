#!/usr/bin/env bash
#
# show-unlinked-postgres-dbs.sh
#
# Interactively browse dokku postgres databases that have no app links,
# and destroy a selected one after confirmation. See
# lib/show-unlinked-db-menu.sh for the shared implementation (also used
# by show-unlinked-mongo-dbs.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_CMD="postgres"
SERVICE_LABEL="Postgres"
source "$SCRIPT_DIR/lib/show-unlinked-db-menu.sh"

run_unlinked_db_menu "$@"

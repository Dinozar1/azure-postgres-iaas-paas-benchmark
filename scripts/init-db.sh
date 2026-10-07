#!/usr/bin/env bash
# Initializes pgbench's schema/data on the target database: pgbench -i -s 1000.
#
# Run once per environment, before the first run-benchmark.sh repetition for
# that config — NOT between repetitions of the same config. Per CLAUDE.md,
# state reset between repeats of the same config is TRUNCATE pgbench_history +
# VACUUM ANALYZE (done at the end of run-benchmark.sh); a full reinit only
# happens on config change.
#
# Records results/<environment>/init-<timestamp>.env: start, end, duration and
# the resulting database size. The end time matters beyond bookkeeping —
# loading ~13 GB is itself a heavy write load that spends disk burst credits,
# so run-benchmark.sh counts it as the previous load when it records the idle
# gap before the burn-in.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_env_arg
ENV_NAME="$1"
require_env_dir "$ENV_NAME"

resolve_db_target "$ENV_NAME" "$ENV_DIR"
push_pgpass "$ENV_DIR"

CLIENT_IP="$(tf_output "$ENV_DIR" client_vm_public_ip)"

echo "== $ENV_NAME: pgbench -i -s $PGBENCH_SCALE against $DB_HOST =="

INIT_START="$(now_iso)"
# pgbench's own output goes to stderr so it streams to the terminal; stdout
# carries only the database size.
DB_SIZE_BYTES="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CLIENT_IP}" \
  bash -s -- "$DB_HOST" "$DB_USER" "$DB_NAME" "$DB_PORT" "$PGBENCH_SCALE" <<'REMOTE_SCRIPT'
set -euo pipefail
DB_HOST="$1"; DB_USER="$2"; DB_NAME="$3"; DB_PORT="$4"; SCALE="$5"
pgbench -i -s "$SCALE" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME" >&2
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -X -At \
  -c "SELECT pg_database_size(current_database())"
REMOTE_SCRIPT
)"
INIT_END="$(now_iso)"
INIT_SECONDS=$(($(iso_to_epoch "$INIT_END") - $(iso_to_epoch "$INIT_START")))

mkdir -p "$RESULTS_ROOT/$ENV_NAME"
INIT_FILE="$RESULTS_ROOT/$ENV_NAME/init-$(date -u -d "$INIT_START" +%Y%m%dT%H%M%SZ).env"
cat >"$INIT_FILE" <<META
ENV_NAME=$ENV_NAME
PGBENCH_SCALE=$PGBENCH_SCALE
INIT_START=$INIT_START
INIT_END=$INIT_END
INIT_SECONDS=$INIT_SECONDS
DB_SIZE_BYTES=$DB_SIZE_BYTES
META

echo "Done: $ENV_NAME initialized (scale factor $PGBENCH_SCALE) in $((INIT_SECONDS / 60))m $((INIT_SECONDS % 60))s," \
  "database size $(awk -v b="$DB_SIZE_BYTES" 'BEGIN { printf "%.1f GiB", b / 1073741824 }')."
echo "Recorded: $INIT_FILE"

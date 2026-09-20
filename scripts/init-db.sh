#!/usr/bin/env bash
# Initializes pgbench's schema/data on the target database: pgbench -i -s 1000.
#
# Run once per environment, before the first run-benchmark.sh repetition for
# that config — NOT between repetitions of the same config. Per CLAUDE.md,
# state reset between repeats of the same config is VACUUM ANALYZE (done at
# the end of run-benchmark.sh); a full reinit only happens on config change.
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

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CLIENT_IP}" \
  bash -s -- "$DB_HOST" "$DB_USER" "$DB_NAME" "$DB_PORT" "$PGBENCH_SCALE" <<'REMOTE_SCRIPT'
set -euo pipefail
DB_HOST="$1"; DB_USER="$2"; DB_NAME="$3"; DB_PORT="$4"; SCALE="$5"
pgbench -i -s "$SCALE" -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME"
REMOTE_SCRIPT

echo "Done: $ENV_NAME initialized (scale factor $PGBENCH_SCALE)."

#!/usr/bin/env bash
# Runs one benchmark repetition against an already-initialized database
# (see init-db.sh): warm-up (uncounted) + measured run
# (pgbench -c 25 -j 2 -T 720 -P 60 -l, per CLAUDE.md/promotor spec) +
# VACUUM ANALYZE to reset state before the next repetition of this config.
#
# Pulls the run's results back to results/<environment>/<run-id>/ locally.
# Safe to call repeatedly for the same environment — each run gets its own
# timestamped directory, both on the client VM and locally.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_env_arg
ENV_NAME="$1"
require_env_dir "$ENV_NAME"

resolve_db_target "$ENV_NAME" "$ENV_DIR"
push_pgpass "$ENV_DIR"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
CLIENT_IP="$(tf_output "$ENV_DIR" client_vm_public_ip)"

echo "== $ENV_NAME / run $RUN_ID: warm-up (${WARMUP_SECONDS}s, not counted) + measured run (${MEASURE_SECONDS}s) =="

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CLIENT_IP}" \
  bash -s -- "$DB_HOST" "$DB_USER" "$DB_NAME" "$DB_PORT" "$ENV_NAME" "$RUN_ID" \
  "$WARMUP_SECONDS" "$MEASURE_SECONDS" "$PGBENCH_CLIENTS" "$PGBENCH_JOBS" "$PROGRESS_INTERVAL" <<'REMOTE_SCRIPT'
set -euo pipefail
DB_HOST="$1"; DB_USER="$2"; DB_NAME="$3"; DB_PORT="$4"; ENV_NAME="$5"; RUN_ID="$6"
WARMUP_SECONDS="$7"; MEASURE_SECONDS="$8"; CLIENTS="$9"; JOBS="${10}"; PROGRESS_INTERVAL="${11}"

RESULTS_DIR="$HOME/pgbench-results/${ENV_NAME}/${RUN_ID}"
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

echo "-- warm-up --"
pgbench -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "$CLIENTS" -j "$JOBS" -T "$WARMUP_SECONDS" "$DB_NAME" >warmup.txt 2>&1

echo "-- measured run --"
pgbench -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "$CLIENTS" -j "$JOBS" -T "$MEASURE_SECONDS" -P "$PROGRESS_INTERVAL" -l "$DB_NAME" >summary.txt 2>&1

echo "-- VACUUM ANALYZE --"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "VACUUM ANALYZE;" >vacuum.txt 2>&1
REMOTE_SCRIPT

echo "== pulling results back to $RESULTS_ROOT/$ENV_NAME/$RUN_ID =="
mkdir -p "$RESULTS_ROOT/$ENV_NAME"
client_vm_scp_from "$ENV_DIR" "pgbench-results/${ENV_NAME}/${RUN_ID}" "$RESULTS_ROOT/$ENV_NAME/$RUN_ID"

echo "Done: $RESULTS_ROOT/$ENV_NAME/$RUN_ID"

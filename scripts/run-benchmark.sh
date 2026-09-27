#!/usr/bin/env bash
# Runs one benchmark repetition against an already-initialized database
# (see init-db.sh): warm-up (uncounted) + measured run
# (pgbench -c 25 -j 2 -T 720 -P 60 -l, per CLAUDE.md/promotor spec) +
# VACUUM ANALYZE to reset state before the next repetition of this config.
#
# Usage: run-benchmark.sh <environment> [--burn-in]
#
# --burn-in performs the identical sequence but marks the run as excluded from
# the dataset. Run it once after init-db.sh: a freshly created disk starts with
# a full burst-credit pool, so the first sustained run measures a bursting disk
# rather than the steady state the disk tier actually provides. The burn-in
# drains that pool; collect-results.sh skips these runs.
#
# Pulls results back to results/<environment>/<run-id>/ and records the measured
# run's exact time window, which collect-results.sh needs to line the run up
# against Azure Monitor metrics.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_env_arg
ENV_NAME="$1"
shift
require_env_dir "$ENV_NAME"

BURN_IN=false
while [ $# -gt 0 ]; do
  case "$1" in
  --burn-in) BURN_IN=true ;;
  *)
    echo "Unknown option: $1" >&2
    usage_env_arg
    ;;
  esac
  shift
done

resolve_db_target "$ENV_NAME" "$ENV_DIR"
push_pgpass "$ENV_DIR"

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
$BURN_IN && RUN_ID="burnin-$RUN_ID"
CLIENT_IP="$(tf_output "$ENV_DIR" client_vm_public_ip)"

if $BURN_IN; then
  echo "== $ENV_NAME / BURN-IN $RUN_ID (drains disk burst credits, excluded from dataset) =="
else
  echo "== $ENV_NAME / run $RUN_ID: warm-up (${WARMUP_SECONDS}s, not counted) + measured run (${MEASURE_SECONDS}s) =="
fi

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

# The window is recorded around the measured run only, excluding warm-up and
# vacuum, so Azure Monitor series can be reduced over exactly the interval the
# reported TPS/latency come from.
echo "-- measured run --"
echo "MEASURE_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >window.env
pgbench -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "$CLIENTS" -j "$JOBS" -T "$MEASURE_SECONDS" -P "$PROGRESS_INTERVAL" -l "$DB_NAME" >summary.txt 2>&1
echo "MEASURE_END=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>window.env

echo "-- VACUUM ANALYZE --"
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "VACUUM ANALYZE;" >vacuum.txt 2>&1
REMOTE_SCRIPT

echo "== pulling results back to $RESULTS_ROOT/$ENV_NAME/$RUN_ID =="
mkdir -p "$RESULTS_ROOT/$ENV_NAME"
client_vm_scp_from "$ENV_DIR" "pgbench-results/${ENV_NAME}/${RUN_ID}" "$RESULTS_ROOT/$ENV_NAME/$RUN_ID"

# Recorded now, while the environment still exists: after terraform destroy the
# resource id is no longer obtainable from state, and Azure stops serving
# metrics for a deleted resource.
cat >"$RESULTS_ROOT/$ENV_NAME/$RUN_ID/meta.env" <<EOF
ENV_NAME=$ENV_NAME
RUN_ID=$RUN_ID
BURN_IN=$BURN_IN
METRICS_RESOURCE_ID=$(tf_output "$ENV_DIR" metrics_resource_id)
EOF

echo "Done: $RESULTS_ROOT/$ENV_NAME/$RUN_ID"
$BURN_IN && echo "NOTE: burn-in run, excluded from the dataset by collect-results.sh"
exit 0

#!/usr/bin/env bash
# Runs one benchmark repetition against an already-initialized database
# (see init-db.sh): warm-up (uncounted) + measured run
# (pgbench -c 25 -j 2 -T 720 -P 60 -l, per CLAUDE.md/promotor spec) +
# TRUNCATE pgbench_history and VACUUM ANALYZE to reset state before the next
# repetition of this config.
#
# Usage: run-benchmark.sh <environment> [--burn-in]
#
# --burn-in precedes the repetition with one continuous pgbench of
# BURN_IN_SECONDS (35 min) — no warm-up, no per-transaction log, no reset —
# and goes straight on into the repetition. Use it for the first repetition
# after init-db.sh: a freshly created disk starts with a full burst-credit
# pool, so the first sustained load measures a bursting disk rather than the
# steady state the disk tier actually provides, and a single standard run is
# too short to empty that pool. Nothing may sit between the burn-in and the
# measurement, because idle time is exactly what refills the pool (a Standard
# SSD E20 refills completely in about 6 minutes). So the per-minute report on
# the burn-in window — credits, IOPS, CPU — is produced in the background once
# Azure Monitor has ingested its last minutes, saved to burnin-metrics.txt and
# printed at the end. collect-results.sh skips burn-in runs.
#
# Around the measured run (immediately before and after it) the script
# snapshots pg_stat_io, pg_stat_database and pg_stat_bgwriter, and once per run
# records the server version and pg_stat_ssl for its own connection — the same
# queries on IaaS and PaaS, so the database's own view of I/O is comparable
# across both arms independently of what each platform's metrics expose.
#
# Pulls results back to results/<environment>/<run-id>/. window.env holds the
# run's timestamps (load start, measured window, end), which collect-results.sh
# needs to line the run up against Azure Monitor metrics; meta.env records when
# the previous load on this environment ended, i.e. how long the disk had to
# refill its credits before this run.
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

CLIENT_IP="$(tf_output "$ENV_DIR" client_vm_public_ip)"
# Read now, while the environment certainly exists: after terraform destroy
# the resource id is no longer obtainable from state, and Azure stops serving
# metrics for a deleted resource.
METRICS_RESOURCE_ID="$(tf_output "$ENV_DIR" metrics_resource_id)"
mkdir -p "$RESULTS_ROOT/$ENV_NAME"

# run_on_client <burnin|measure> <run_id>
#
# Executes one load on the client VM, pulls its output back to
# results/<environment>/<run_id>/ and writes meta.env there.
run_on_client() {
  local mode="$1" run_id="$2"
  local run_dir="$RESULTS_ROOT/$ENV_NAME/$run_id"
  local prev_run_end load_start idle_gap="" burn_in=false
  if [ "$mode" = burnin ]; then burn_in=true; fi
  if [ -e "$run_dir" ]; then
    echo "ERROR: $run_dir already exists — refusing to overwrite an earlier run" >&2
    exit 1
  fi
  prev_run_end="$(latest_load_end "$RESULTS_ROOT/$ENV_NAME")"

  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CLIENT_IP}" \
    bash -s -- "$mode" "$DB_HOST" "$DB_USER" "$DB_NAME" "$DB_PORT" "$ENV_NAME" "$run_id" \
    "$WARMUP_SECONDS" "$MEASURE_SECONDS" "$BURN_IN_SECONDS" \
    "$PGBENCH_CLIENTS" "$PGBENCH_JOBS" "$PROGRESS_INTERVAL" <<'REMOTE_SCRIPT'
set -euo pipefail
MODE="$1"; DB_HOST="$2"; DB_USER="$3"; DB_NAME="$4"; DB_PORT="$5"; ENV_NAME="$6"; RUN_ID="$7"
WARMUP_SECONDS="$8"; MEASURE_SECONDS="$9"; BURN_IN_SECONDS="${10}"
CLIENTS="${11}"; JOBS="${12}"; PROGRESS_INTERVAL="${13}"

RESULTS_DIR="$HOME/pgbench-results/${ENV_NAME}/${RUN_ID}"
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

CONN=(-h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER")
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
sql() { psql "${CONN[@]}" -d "$DB_NAME" -X -q -v ON_ERROR_STOP=1 "$@"; }

# Once per run. pg_stat_ssl is read for psql's own backend: pgbench uses the
# same libpq defaults (sslmode=prefer), so this shows whether, and with which
# protocol/cipher, the benchmark traffic itself was encrypted.
sql --csv -c "SELECT current_setting('server_version') AS server_version, version() AS version" >version.csv
sql --csv -c "SELECT * FROM pg_stat_ssl WHERE pid = pg_backend_pid()" >pg_stat_ssl.csv

# Cumulative statistics, server-wide (pg_stat_io, pg_stat_bgwriter) and for
# the benchmark database; collect-results.sh works with the after-before delta.
snapshot() {
  sql --csv <<SQL
\o pg_stat_io.$1.csv
SELECT now() AS snapshot_at, * FROM pg_stat_io;
\o pg_stat_database.$1.csv
SELECT now() AS snapshot_at, * FROM pg_stat_database WHERE datname = current_database();
\o pg_stat_bgwriter.$1.csv
SELECT now() AS snapshot_at, * FROM pg_stat_bgwriter;
SQL
}

echo "LOAD_START=$(now)" >window.env

if [ "$MODE" = burnin ]; then
  echo "-- burn-in: continuous pgbench for ${BURN_IN_SECONDS}s --"
  echo "MEASURE_START=$(now)" >>window.env
  pgbench "${CONN[@]}" -c "$CLIENTS" -j "$JOBS" -T "$BURN_IN_SECONDS" -P "$PROGRESS_INTERVAL" "$DB_NAME" >summary.txt 2>&1
  echo "MEASURE_END=$(now)" >>window.env
else
  echo "-- warm-up --"
  pgbench "${CONN[@]}" -c "$CLIENTS" -j "$JOBS" -T "$WARMUP_SECONDS" "$DB_NAME" >warmup.txt 2>&1

  # A failed snapshot must not cost the measured run, so failures only warn.
  # The window is recorded around the measured run only, excluding warm-up and
  # reset, so Azure Monitor series can be reduced over exactly the interval the
  # reported TPS/latency come from.
  snapshot before || echo "WARNING: pg_stat snapshot before the measured run failed" >&2
  echo "-- measured run --"
  echo "MEASURE_START=$(now)" >>window.env
  pgbench "${CONN[@]}" -c "$CLIENTS" -j "$JOBS" -T "$MEASURE_SECONDS" -P "$PROGRESS_INTERVAL" -l "$DB_NAME" >summary.txt 2>&1
  echo "MEASURE_END=$(now)" >>window.env
  snapshot after || echo "WARNING: pg_stat snapshot after the measured run failed" >&2

  # pgbench_history is append-only and only ever grows; truncating it first
  # also spares VACUUM a scan of rows nothing reads again.
  echo "-- reset: TRUNCATE pgbench_history + VACUUM ANALYZE --"
  sql -c "TRUNCATE pgbench_history;" -c "VACUUM ANALYZE;" >vacuum.txt 2>&1
fi

echo "RUN_END=$(now)" >>window.env
REMOTE_SCRIPT

  echo "== pulling results back to $run_dir =="
  client_vm_scp_from "$ENV_DIR" "pgbench-results/${ENV_NAME}/${run_id}" "$run_dir"

  load_start="$(env_get "$run_dir/window.env" LOAD_START)"
  if [ -n "$prev_run_end" ] && [ -n "$load_start" ]; then
    idle_gap=$(($(iso_to_epoch "$load_start") - $(iso_to_epoch "$prev_run_end")))
  fi

  # PREV_RUN_END is the end of the previous load on this environment (an
  # earlier run, a burn-in or init-db.sh); IDLE_GAP_S the seconds from there
  # to this run's first query — the time the disk had to refill.
  cat >"$run_dir/meta.env" <<META
ENV_NAME=$ENV_NAME
RUN_ID=$run_id
BURN_IN=$burn_in
METRICS_RESOURCE_ID=$METRICS_RESOURCE_ID
PREV_RUN_END=$prev_run_end
IDLE_GAP_S=$idle_gap
META

  if [ -n "$idle_gap" ]; then
    echo "Idle gap since the previous load on $ENV_NAME ($prev_run_end): ${idle_gap}s"
  fi
}

REPORT_PID=""
if $BURN_IN; then
  BURN_IN_ID="burnin-$(date -u +%Y%m%dT%H%M%SZ)"
  BURN_IN_DIR="$RESULTS_ROOT/$ENV_NAME/$BURN_IN_ID"
  echo "== $ENV_NAME / BURN-IN $BURN_IN_ID: continuous load for ${BURN_IN_SECONDS}s (drains burst credits, excluded from dataset) =="
  run_on_client burnin "$BURN_IN_ID"

  # In the background, so the measured run starts now rather than after the
  # ingestion lag: those minutes of idle disk would refill the credits the
  # burn-in has just spent.
  nohup bash -c 'source "$1"; sleep "$2"; report_burn_in "$3" "$4" "$5"' _ \
    "$SCRIPT_DIR/lib/common.sh" "$METRIC_INGESTION_LAG_SECONDS" "$METRICS_RESOURCE_ID" \
    "$(env_get "$BURN_IN_DIR/window.env" LOAD_START)" \
    "$(env_get "$BURN_IN_DIR/window.env" MEASURE_END)" \
    >"$BURN_IN_DIR/burnin-metrics.txt" 2>&1 </dev/null &
  REPORT_PID=$!
  echo "== burn-in report: in the background, ready in ~${METRIC_INGESTION_LAG_SECONDS}s at $BURN_IN_DIR/burnin-metrics.txt =="
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
echo "== $ENV_NAME / run $RUN_ID: warm-up (${WARMUP_SECONDS}s, not counted) + measured run (${MEASURE_SECONDS}s) =="
run_on_client measure "$RUN_ID"
echo "Done: $RESULTS_ROOT/$ENV_NAME/$RUN_ID"

if [ -n "$REPORT_PID" ]; then
  wait "$REPORT_PID" || true
  echo
  echo "== burn-in $BURN_IN_ID ($BURN_IN_DIR/burnin-metrics.txt) =="
  cat "$BURN_IN_DIR/burnin-metrics.txt"
fi
exit 0

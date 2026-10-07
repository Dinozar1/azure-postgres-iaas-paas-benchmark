#!/usr/bin/env bash
# Runs one benchmark repetition against an already-initialized database
# (see init-db.sh): warm-up (uncounted) + measured run
# (pgbench -c 25 -j 2 -T 720 -P 60 -l, per CLAUDE.md/promotor spec) +
# TRUNCATE pgbench_history and VACUUM ANALYZE to reset state before the next
# repetition of this config.
#
# Usage: run-benchmark.sh <environment> [--burn-in]
#
# --burn-in replaces that sequence with one continuous pgbench of
# BURN_IN_SECONDS (35 min) — no warm-up, no per-transaction log, no reset —
# then waits out the Azure Monitor ingestion lag and prints the credit balance
# it was meant to drain. Run it once after init-db.sh: a freshly created disk
# starts with a full burst-credit pool, so the first sustained load measures a
# bursting disk rather than the steady state the disk tier actually provides,
# and a single standard run is too short to empty that pool. collect-results.sh
# skips burn-in runs.
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

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
MODE=measure
if $BURN_IN; then
  RUN_ID="burnin-$RUN_ID"
  MODE=burnin
fi
CLIENT_IP="$(tf_output "$ENV_DIR" client_vm_public_ip)"
RUN_DIR="$RESULTS_ROOT/$ENV_NAME/$RUN_ID"
PREV_RUN_END="$(latest_load_end "$RESULTS_ROOT/$ENV_NAME")"

if $BURN_IN; then
  echo "== $ENV_NAME / BURN-IN $RUN_ID: continuous load for ${BURN_IN_SECONDS}s (drains burst credits, excluded from dataset) =="
else
  echo "== $ENV_NAME / run $RUN_ID: warm-up (${WARMUP_SECONDS}s, not counted) + measured run (${MEASURE_SECONDS}s) =="
fi

ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CLIENT_IP}" \
  bash -s -- "$MODE" "$DB_HOST" "$DB_USER" "$DB_NAME" "$DB_PORT" "$ENV_NAME" "$RUN_ID" \
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

echo "== pulling results back to $RUN_DIR =="
mkdir -p "$RESULTS_ROOT/$ENV_NAME"
client_vm_scp_from "$ENV_DIR" "pgbench-results/${ENV_NAME}/${RUN_ID}" "$RUN_DIR"

LOAD_START="$(env_get "$RUN_DIR/window.env" LOAD_START)"
IDLE_GAP_S=""
if [ -n "$PREV_RUN_END" ] && [ -n "$LOAD_START" ]; then
  IDLE_GAP_S=$(($(iso_to_epoch "$LOAD_START") - $(iso_to_epoch "$PREV_RUN_END")))
fi
METRICS_RESOURCE_ID="$(tf_output "$ENV_DIR" metrics_resource_id)"

# Recorded now, while the environment still exists: after terraform destroy the
# resource id is no longer obtainable from state, and Azure stops serving
# metrics for a deleted resource. PREV_RUN_END is the end of the previous load
# on this environment (an earlier run or init-db.sh); IDLE_GAP_S the seconds
# from there to this run's first query — the time the disk had to refill.
cat >"$RUN_DIR/meta.env" <<META
ENV_NAME=$ENV_NAME
RUN_ID=$RUN_ID
BURN_IN=$BURN_IN
METRICS_RESOURCE_ID=$METRICS_RESOURCE_ID
PREV_RUN_END=$PREV_RUN_END
IDLE_GAP_S=$IDLE_GAP_S
META

# Prints the credit balance(s) over the burn-in, once Azure Monitor has caught
# up with its last minutes, to show the pool really is drained. Never fails:
# the burn-in itself has already done its job.
report_burn_in_credits() {
  local rid="$1" since="$2" available m metrics=() json
  available="$(published_metrics "$rid")"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    if grep -qxF "$m" <<<"$available"; then
      metrics+=("$m")
    else
      echo "NOTE: '$m' is not published by this resource, not reported" >&2
    fi
  done < <(burn_in_metrics_for "$rid" || true)
  if [ ${#metrics[@]} -eq 0 ]; then
    echo "NOTE: no credit metric to report for $rid"
    return 0
  fi

  echo "== waiting ${METRIC_INGESTION_LAG_SECONDS}s for Azure Monitor ingestion =="
  sleep "$METRIC_INGESTION_LAG_SECONDS"

  json="$(az monitor metrics list --resource "$rid" --metric "${metrics[@]}" \
    --start-time "$since" --end-time "$(now_iso)" \
    --interval PT5M --aggregation Minimum Maximum -o json 2>/dev/null || true)"
  if [ -z "$json" ]; then
    echo "WARNING: credit metric query failed for $rid" >&2
    return 0
  fi
  python3 -c '
import json, sys
for m in json.load(sys.stdin).get("value", []):
    print(m["name"]["value"] + "  (per 5 min: min / max)")
    pts = [p for ts in m.get("timeseries", []) for p in ts.get("data", [])
           if p.get("minimum") is not None or p.get("maximum") is not None]
    if not pts:
        print("  no data points yet")
    for p in pts:
        low, high = (f"{v:.1f}" if v is not None else "-" for v in (p.get("minimum"), p.get("maximum")))
        stamp = p["timeStamp"]
        print(f"  {stamp}  {low} / {high}")
' <<<"$json"
}

if $BURN_IN; then
  report_burn_in_credits "$METRICS_RESOURCE_ID" "$LOAD_START" | tee "$RUN_DIR/burnin-credits.txt"
fi

echo "Done: $RUN_DIR"
if [ -n "$IDLE_GAP_S" ]; then
  echo "Idle gap since the previous load on $ENV_NAME ($PREV_RUN_END): ${IDLE_GAP_S}s"
fi
if $BURN_IN; then
  echo "NOTE: burn-in run, excluded from the dataset by collect-results.sh"
fi
exit 0

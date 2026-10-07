#!/usr/bin/env bash
# Runs one benchmark repetition against an already-initialized database
# (see init-db.sh): warm-up (uncounted) + measured run
# (pgbench -c 25 -j 2 -T 720 -P 60 -l, per CLAUDE.md/promotor spec) +
# TRUNCATE pgbench_history and VACUUM ANALYZE to reset state before the next
# repetition of this config.
#
# Usage: run-benchmark.sh <environment> [--burn-in] [--phase pilot|main|explanatory]
#
# --phase records which part of the campaign the run belongs to (meta.env,
# phase column of summary.csv). Default pilot: only runs explicitly marked
# main make the final dataset. The explanatory environment
# (iaas-premium-ssd-readcache) always runs, and defaults to, phase explanatory.
#
# --burn-in precedes the repetition with one continuous pgbench — no warm-up,
# no per-transaction log, no reset — and goes straight on into the repetition.
# Use it for the first repetition after init-db.sh. The burn-in runs until
# every credit pool that drains under this load has drained, and never less
# than BURN_IN_SECONDS (60 min): a freshly created resource starts with full
# pools, so without it the first sustained load measures a bursting resource
# rather than the state the configuration holds indefinitely. The pools to
# watch come from burn_in_pools in lib/common.sh: the Burstable tier's CPU
# credits always drain and are run down until spent; on IaaS the disk pool
# and the VM's CPU credits are followed while they are still draining. The
# load keeps running while the pools are read from Azure Monitor every
# BURN_IN_CHECK_SECONDS; a pool that reads spent gets
# BURN_IN_DRAIN_MARGIN_SECONDS more to cover metric lag, and the burn-in stops
# once every pool is spent or (where allowed) has levelled out, with
# BURN_IN_MAX_SECONDS as a safety limit.
#
# Nothing may sit between the burn-in and the measurement, because idle time
# is exactly what refills the pools (a Standard SSD E20 refills completely in
# about 6 minutes). So the per-minute report on the burn-in window — credits,
# IOPS, CPU — and the raw metric series behind it are produced in the
# background once Azure Monitor has ingested the last minutes, saved as
# burnin-metrics.txt and burnin-azure-metrics.json, and printed at the end.
# The burn-in's own -P 60 progress log (summary.txt in its directory) is kept:
# it is the data on the bursting phase itself. collect-results.sh skips
# burn-in runs.
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
# the previous load on this environment ended, i.e. how long the resource had
# to refill its credits before this run.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  echo "Usage: $(basename "$0") <environment> [--burn-in] [--phase pilot|main|explanatory]" >&2
  echo "  environment: one of $VALID_ENVIRONMENTS" >&2
  exit 1
}

[ $# -ge 1 ] || usage
ENV_NAME="$1"
shift
require_env_dir "$ENV_NAME"

BURN_IN=false
PHASE=""
while [ $# -gt 0 ]; do
  case "$1" in
  --burn-in) BURN_IN=true ;;
  --phase)
    [ $# -ge 2 ] || usage
    PHASE="$2"
    shift
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    ;;
  esac
  shift
done
PHASE="${PHASE:-$(default_phase_for "$ENV_NAME")}"
check_phase "$ENV_NAME" "$PHASE"

resolve_db_target "$ENV_NAME" "$ENV_DIR"
push_pgpass "$ENV_DIR"

CLIENT_IP="$(tf_output "$ENV_DIR" client_vm_public_ip)"
# Read now, while the environment certainly exists: after terraform destroy
# the resource id is no longer obtainable from state, and Azure stops serving
# metrics for a deleted resource.
METRICS_RESOURCE_ID="$(tf_output "$ENV_DIR" metrics_resource_id)"
mkdir -p "$RESULTS_ROOT/$ENV_NAME"

# An interrupted or failed local ssh does not stop pgbench on the client, which
# would go on loading the database for the rest of its -T — up to
# BURN_IN_MAX_SECONDS for an adaptive burn-in. So on any non-zero exit,
# Ctrl+C included, the load on the client is stopped explicitly.
REMOTE_PID=""
stop_remote_load() {
  if [ -n "$REMOTE_PID" ]; then kill "$REMOTE_PID" 2>/dev/null || true; fi
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${CLIENT_IP}" "pkill -x pgbench" 2>/dev/null || true
}
on_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ]; then
    echo "!! run-benchmark.sh failed or was interrupted — stopping pgbench on the client" >&2
    stop_remote_load
  fi
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# remote_run <burnin|measure> <run_id> <burn_in_seconds> <stoppable>
#
# Executes one load on the client VM over SSH. With stoppable=1 the burn-in's
# pgbench may be ended early by a signal (watch_burn_in) without that
# counting as a failure.
remote_run() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CLIENT_IP}" \
    bash -s -- "$1" "$DB_HOST" "$DB_USER" "$DB_NAME" "$DB_PORT" "$ENV_NAME" "$2" \
    "$WARMUP_SECONDS" "$MEASURE_SECONDS" "$3" \
    "$PGBENCH_CLIENTS" "$PGBENCH_JOBS" "$PROGRESS_INTERVAL" "$4" <<'REMOTE_SCRIPT'
set -euo pipefail
MODE="$1"; DB_HOST="$2"; DB_USER="$3"; DB_NAME="$4"; DB_PORT="$5"; ENV_NAME="$6"; RUN_ID="$7"
WARMUP_SECONDS="$8"; MEASURE_SECONDS="$9"; BURN_IN_SECONDS="${10}"
CLIENTS="${11}"; JOBS="${12}"; PROGRESS_INTERVAL="${13}"; STOPPABLE="${14}"

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
  echo "-- burn-in: continuous pgbench, up to ${BURN_IN_SECONDS}s --"
  echo "MEASURE_START=$(now)" >>window.env
  # A stoppable burn-in ends on a signal once its pool has drained; pgbench
  # then exits non-zero without its closing summary, which is expected — the
  # -P 60 progress lines already in summary.txt are the record.
  status=0
  pgbench "${CONN[@]}" -c "$CLIENTS" -j "$JOBS" -T "$BURN_IN_SECONDS" -P "$PROGRESS_INTERVAL" "$DB_NAME" >summary.txt 2>&1 || status=$?
  if [ "$status" -ne 0 ] && [ "$STOPPABLE" != 1 ]; then
    echo "pgbench burn-in failed with status $status" >&2
    exit "$status"
  fi
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
}

# watch_burn_in <remote_pid> <out_file>
#
# Runs alongside a stoppable burn-in. Every BURN_IN_CHECK_SECONDS it reads each
# pool from burn_in_pools; once BURN_IN_SECONDS have passed and every pool is
# done — spent for BURN_IN_DRAIN_MARGIN_SECONDS, or, in while_draining mode, no
# longer draining over the last BURN_IN_TREND_SECONDS — it stops the load
# (SIGTERM to pgbench on the client). If pgbench ends by itself first, the
# safety limit was hit. Writes BURN_IN_STOP=done|limit and BURN_IN_POOLS (the
# final state of every pool) to out_file.
watch_burn_in() {
  local pid="$1" out="$2"
  local start elapsed now i line metric kind spent_at mode reading
  local latest earliest span stamp state summary all_done
  local -a metrics=() kinds=() spent_ats=() modes=() spent_since=() states=()
  while IFS='|' read -r metric kind spent_at mode; do
    [ -n "$metric" ] || continue
    metrics+=("$metric"); kinds+=("$kind"); spent_ats+=("$spent_at"); modes+=("$mode")
    spent_since+=(""); states+=("unknown")
  done < <(burn_in_pools "$ENV_NAME")

  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$BURN_IN_CHECK_SECONDS"
    kill -0 "$pid" 2>/dev/null || break
    now=$(date +%s)
    elapsed=$((now - start))
    all_done=true
    summary=""
    for i in "${!metrics[@]}"; do
      reading="$(metric_trend "$METRICS_RESOURCE_ID" "${metrics[$i]}" "$BURN_IN_TREND_SECONDS")"
      read -r latest earliest span stamp <<<"$reading"
      if [ -z "$latest" ]; then
        state="no-data"
      elif awk -v v="$latest" -v t="${spent_ats[$i]}" -v k="${kinds[$i]}" \
        'BEGIN { exit !(k == "used" ? v >= t : v <= t) }'; then
        [ -n "${spent_since[$i]}" ] || spent_since[i]=$now
        if [ $((now - spent_since[i])) -ge "$BURN_IN_DRAIN_MARGIN_SECONDS" ]; then
          state="spent"
        else
          state="spent-margin"
        fi
      elif [ "${modes[$i]}" = while_draining ] && [ "${span:-0}" -ge "$BURN_IN_TREND_MIN_SPAN" ] &&
        awk -v l="$latest" -v e="$earliest" -v k="${kinds[$i]}" \
          -v ut="$BURN_IN_TREND_USED_PCT_TOL" -v ct="$BURN_IN_TREND_CREDITS_TOL" \
          'BEGIN { exit !(k == "used" ? l - e <= ut : e - l <= ct) }'; then
        state="level"
      else
        state="draining"
      fi
      states[i]="$state"
      case "$state" in spent | level) ;; *) all_done=false ;; esac
      summary+="${summary:+; }${metrics[$i]}=${latest:-?} ($state)"
    done
    echo "   burn-in $((elapsed / 60)) min: $summary"
    if [ "$elapsed" -ge "$BURN_IN_SECONDS" ] && $all_done; then
      echo "   every pool spent or levelled out: stopping the burn-in after $((elapsed / 60)) min"
      ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CLIENT_IP}" "pkill -x pgbench" || true
      printf 'BURN_IN_STOP=done\nBURN_IN_POOLS=%s\n' "$summary" >"$out"
      return 0
    fi
  done
  echo "WARNING: burn-in reached the ${BURN_IN_MAX_SECONDS}s safety limit before every pool was spent" \
    "or levelled out; the runs that follow may fail the steady-state criterion" >&2
  printf 'BURN_IN_STOP=limit\nBURN_IN_POOLS=%s\n' "$summary" >"$out"
}

# run_on_client <burnin|measure> <run_id>
#
# Executes one load on the client VM, pulls its output back to
# results/<environment>/<run_id>/ and writes meta.env there.
run_on_client() {
  local mode="$1" run_id="$2"
  local run_dir="$RESULTS_ROOT/$ENV_NAME/$run_id"
  local prev_run_end load_start idle_gap="" burn_in=false pools="" stop_file=""
  if [ "$mode" = burnin ]; then burn_in=true; fi
  if [ -e "$run_dir" ]; then
    echo "ERROR: $run_dir already exists — refusing to overwrite an earlier run" >&2
    exit 1
  fi
  prev_run_end="$(latest_load_end "$RESULTS_ROOT/$ENV_NAME")"
  if $burn_in; then pools="$(burn_in_pools "$ENV_NAME")"; fi

  if [ -n "$pools" ]; then
    stop_file="$(mktemp)"
    echo "   adaptive burn-in: at least ${BURN_IN_SECONDS}s, at most ${BURN_IN_MAX_SECONDS}s, watching:"
    sed 's/^/     /' <<<"$pools"
    remote_run "$mode" "$run_id" "$BURN_IN_MAX_SECONDS" 1 &
    REMOTE_PID=$!
    watch_burn_in "$REMOTE_PID" "$stop_file"
    wait "$REMOTE_PID"
    REMOTE_PID=""
  else
    remote_run "$mode" "$run_id" "$BURN_IN_SECONDS" 0
  fi

  echo "== pulling results back to $run_dir =="
  client_vm_scp_from "$ENV_DIR" "pgbench-results/${ENV_NAME}/${run_id}" "$run_dir"

  load_start="$(env_get "$run_dir/window.env" LOAD_START)"
  if [ -n "$prev_run_end" ] && [ -n "$load_start" ]; then
    idle_gap=$(($(iso_to_epoch "$load_start") - $(iso_to_epoch "$prev_run_end")))
  fi

  # PREV_RUN_END is the end of the previous load on this environment (an
  # earlier run, a burn-in or init-db.sh); IDLE_GAP_S the seconds from there
  # to this run's first query — the time the resource had to refill.
  cat >"$run_dir/meta.env" <<META
ENV_NAME=$ENV_NAME
RUN_ID=$run_id
PHASE=$PHASE
BURN_IN=$burn_in
METRICS_RESOURCE_ID=$METRICS_RESOURCE_ID
PREV_RUN_END=$prev_run_end
IDLE_GAP_S=$idle_gap
META
  if [ -n "$stop_file" ]; then
    cat "$stop_file" >>"$run_dir/meta.env"
    rm -f "$stop_file"
  fi

  if [ -n "$idle_gap" ]; then
    echo "Idle gap since the previous load on $ENV_NAME ($prev_run_end): ${idle_gap}s"
  fi
}

REPORT_PID=""
if $BURN_IN; then
  BURN_IN_ID="burnin-$(date -u +%Y%m%dT%H%M%SZ)"
  BURN_IN_DIR="$RESULTS_ROOT/$ENV_NAME/$BURN_IN_ID"
  echo "== $ENV_NAME / BURN-IN $BURN_IN_ID (drains credit pools, excluded from dataset) =="
  run_on_client burnin "$BURN_IN_ID"

  # In the background, so the measured run starts now rather than after the
  # ingestion lag: those minutes of idle resource would refill the credits
  # the burn-in has just spent.
  nohup bash -c 'source "$1"; sleep "$2"
    report_burn_in "$3" "$4" "$5"
    fetch_metrics "$3" "$4" "$5" "$6" >/dev/null 2>&1' _ \
    "$SCRIPT_DIR/lib/common.sh" "$METRIC_INGESTION_LAG_SECONDS" "$METRICS_RESOURCE_ID" \
    "$(env_get "$BURN_IN_DIR/window.env" LOAD_START)" \
    "$(env_get "$BURN_IN_DIR/window.env" MEASURE_END)" \
    "$BURN_IN_DIR/burnin-azure-metrics.json" \
    >"$BURN_IN_DIR/burnin-metrics.txt" 2>&1 </dev/null &
  REPORT_PID=$!
  echo "== burn-in report: in the background, ready in ~${METRIC_INGESTION_LAG_SECONDS}s at $BURN_IN_DIR/burnin-metrics.txt =="
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
echo "== $ENV_NAME / run $RUN_ID ($PHASE): warm-up (${WARMUP_SECONDS}s, not counted) + measured run (${MEASURE_SECONDS}s) =="
run_on_client measure "$RUN_ID"
echo "Done: $RESULTS_ROOT/$ENV_NAME/$RUN_ID"

if [ -n "$REPORT_PID" ]; then
  wait "$REPORT_PID" || true
  echo
  echo "== burn-in $BURN_IN_ID ($BURN_IN_DIR/burnin-metrics.txt) =="
  cat "$BURN_IN_DIR/burnin-metrics.txt"
fi
exit 0

#!/usr/bin/env bash
# Aggregates the per-run output pulled locally by run-benchmark.sh
# (results/<environment>/<run-id>/) into results/<environment>/summary.csv,
# one row per measured run:
#   - phase: pilot, main or explanatory (run-benchmark.sh --phase); only main
#     runs make the final dataset
#   - steady_state: whether the run meets the environment's steady-state
#     criterion (lib/common.sh, steady_state); failing runs are kept, flagged
#   - pgbench throughput and latency (summary.txt)
#   - latency percentiles, failed transactions and TPS in the first vs last
#     3 minutes, from the per-transaction log (scripts/lib/run_stats.py)
#   - cache hit ratio, data-file I/O and checkpoints, from the pg_stat_*
#     snapshots around the measured run
#   - Azure Monitor metrics over the measured window: the USOS metrics (IOPS,
#     CPU, memory) plus the credit balances that say whether the run was taken
#     in a bursting or a steady state
#
# Usage: collect-results.sh <environment>
#
# RUN THIS BEFORE terraform destroy (teardown.sh does). Azure serves no metrics
# for a deleted resource, so once the environment is gone the metric columns
# can never be filled in for runs not yet collected — the pgbench numbers
# survive, the context does not. Once a run's metrics are complete and older
# than the ingestion lag, its raw per-minute series (azure-metrics.json) is
# kept and never re-fetched; the columns are reduced from it offline (see
# load_metrics), so collecting again after the environment is gone loses
# nothing.
#
# Runs recorded with --burn-in are skipped: they exist to drain disk burst
# credits, not to be measured.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_env_arg
ENV_NAME="$1"
require_env_dir "$ENV_NAME"

RESULTS_DIR="$RESULTS_ROOT/$ENV_NAME"
if [ ! -d "$RESULTS_DIR" ]; then
  echo "No results found for $ENV_NAME under $RESULTS_DIR (run run-benchmark.sh first)." >&2
  exit 1
fi

# Column set depends on the resource type, which is the same for every run of a
# given environment, so take it from the first run that recorded one.
METRIC_COLUMNS=""
shopt -s nullglob
for meta in "$RESULTS_DIR"/*/meta.env; do
  rid="$(env_get "$meta" METRICS_RESOURCE_ID)"
  if [ -n "$rid" ]; then
    METRIC_COLUMNS="$(metric_columns_for "$rid" || true)"
    break
  fi
done

if [ -z "$METRIC_COLUMNS" ]; then
  echo "NOTE: no run under $RESULTS_DIR recorded a metrics resource id, so the" >&2
  echo "      CSV carries no Azure Monitor columns. Runs made before metric" >&2
  echo "      collection existed, or after terraform destroy, look like this." >&2
fi

STATS_COLUMNS="$(python3 "$SCRIPT_DIR/lib/run_stats.py" --header)"

# Quotes a CSV field only when it has to (server_version strings, mostly).
csv_field() {
  local v="$1"
  if [[ "$v" == *[,\"]* ]]; then
    printf '"%s"' "${v//\"/\"\"}"
  else
    printf '%s' "$v"
  fi
}

# Loads a run's metric columns into the metric_values array. A run whose
# metrics were once fetched complete and past the ingestion lag has a
# metrics.env marker and its raw per-minute series in azure-metrics.json; its
# values are then reduced from that file, offline, so collection keeps working
# after the environment is gone and any fix to the reduction reaches past runs
# (metrics.env is rewritten to match). Otherwise the metrics are fetched from
# Azure Monitor and marked complete only when every required column is filled
# and the window has settled, so a partial or premature read is retried next
# time instead of frozen.
load_metrics() {
  local run_dir="$1" rid="$2" start="$3" end="$4"
  local marker="${run_dir}metrics.env" raw="${run_dir}azure-metrics.json" col val complete=true
  local values

  if [ -f "$marker" ] && [ -f "$raw" ]; then
    values="$(reduce_metrics "$rid" "$raw")"
    printf '%s\n' "$values" >"$marker"
    while IFS='=' read -r col val; do
      [ -n "$col" ] && metric_values["$col"]="$val"
    done <<<"$values"
    return 0
  fi
  if [ -f "$marker" ]; then
    # Collected before the raw series was kept: the reduced values are all there is.
    while IFS='=' read -r col val; do
      [ -n "$col" ] && metric_values["$col"]="$val"
    done <"$marker"
    return 0
  fi

  values="$(fetch_metrics "$rid" "$start" "$end" "$raw")"
  while IFS='=' read -r col val; do
    [ -n "$col" ] && metric_values["$col"]="$val"
  done <<<"$values"

  while read -r col; do
    [ -n "$col" ] || continue
    [ -n "${metric_values[$col]-}" ] || complete=false
  done < <(metric_required_columns_for "$rid" "$ENV_NAME")

  local settled=$(($(date +%s) - $(iso_to_epoch "$end") >= METRIC_INGESTION_LAG_SECONDS))
  if $complete && [ "$settled" -eq 1 ]; then
    printf '%s\n' "$values" >"$marker"
  elif [ "$settled" -eq 0 ]; then
    echo "WARNING: $(basename "$run_dir") ended less than ${METRIC_INGESTION_LAG_SECONDS}s ago;" \
      "its metrics may be partially ingested and will be re-fetched next time" >&2
  fi
}

CSV="$RESULTS_DIR/summary.csv"
{
  printf 'run_id,phase,measure_start,steady_state,idle_gap_s,warmup_s,tps,latency_avg_ms'
  while read -r col; do [ -n "$col" ] && printf ',%s' "$col"; done <<<"$STATS_COLUMNS"
  while read -r col; do [ -n "$col" ] && printf ',%s' "$col"; done <<<"$METRIC_COLUMNS"
  printf '\n'
} >"$CSV"

counted=0
skipped=0

for run_dir in "$RESULTS_DIR"/*/; do
  run_id="$(basename "$run_dir")"
  summary_file="${run_dir}summary.txt"
  [ -f "$summary_file" ] || continue

  meta="${run_dir}meta.env"
  burn_in=false
  [ "$(env_get "$meta" BURN_IN)" = true ] && burn_in=true
  # Older runs predate meta.env; fall back to the directory naming convention.
  [[ "$run_id" == burnin-* ]] && burn_in=true

  if $burn_in; then
    skipped=$((skipped + 1))
    continue
  fi

  tps="$(grep -oP '(?<=^tps = )[0-9.]+' "$summary_file" || true)"
  latency="$(grep -oP '(?<=^latency average = )[0-9.]+' "$summary_file" || true)"

  if [ -z "$tps" ] || [ -z "$latency" ]; then
    echo "WARNING: could not parse $summary_file, skipping" >&2
    skipped=$((skipped + 1))
    continue
  fi

  measure_start="$(env_get "${run_dir}window.env" MEASURE_START)"
  measure_end="$(env_get "${run_dir}window.env" MEASURE_END)"
  idle_gap="$(env_get "$meta" IDLE_GAP_S)"
  phase="$(env_get "$meta" PHASE)"
  warmup_s="$(env_get "$meta" WARMUP_S)"
  metrics_resource_id="$(env_get "$meta" METRICS_RESOURCE_ID)"

  declare -A stat_values=()
  while IFS='=' read -r col val; do
    [ -n "$col" ] && stat_values["$col"]="$val"
  done < <(python3 "$SCRIPT_DIR/lib/run_stats.py" "$run_dir" ||
    echo "WARNING: run_stats.py failed for $run_id, its columns left empty" >&2)

  # Metric values, keyed by CSV column, for this run's measured window.
  declare -A metric_values=()
  if [ -n "$metrics_resource_id" ]; then
    if [ -n "$measure_start" ] && [ -n "$measure_end" ]; then
      load_metrics "$run_dir" "$metrics_resource_id" "$measure_start" "$measure_end"
    else
      echo "WARNING: $run_id has no measured window recorded, metrics left empty" >&2
    fi
  elif [ -n "$METRIC_COLUMNS" ]; then
    echo "WARNING: $run_id predates metric collection, metrics left empty" >&2
  fi

  steady="$(steady_state "$ENV_NAME" \
    "disk_burst_io_pct_min=${metric_values[disk_burst_io_pct_min]-}" \
    "disk_burst_io_pct_first=${metric_values[disk_burst_io_pct_first]-}" \
    "disk_burst_io_pct_last=${metric_values[disk_burst_io_pct_last]-}" \
    "cpu_credits_remaining_min=${metric_values[cpu_credits_remaining_min]-}" \
    "cpu_credits_remaining_max=${metric_values[cpu_credits_remaining_max]-}" \
    "cpu_credits_remaining_first=${metric_values[cpu_credits_remaining_first]-}" \
    "cpu_credits_remaining_last=${metric_values[cpu_credits_remaining_last]-}")"

  {
    printf '%s,%s,%s,%s,%s,%s,%s,%s' "$run_id" "$phase" "$measure_start" "$steady" "$idle_gap" "$warmup_s" "$tps" "$latency"
    while read -r col; do
      [ -n "$col" ] && printf ',%s' "$(csv_field "${stat_values[$col]-}")"
    done <<<"$STATS_COLUMNS"
    while read -r col; do
      [ -n "$col" ] && printf ',%s' "$(csv_field "${metric_values[$col]-}")"
    done <<<"$METRIC_COLUMNS"
    printf '\n'
  } >>"$CSV"

  counted=$((counted + 1))
  unset stat_values metric_values
done

echo "Written: $CSV ($counted runs in the dataset, $skipped skipped)"

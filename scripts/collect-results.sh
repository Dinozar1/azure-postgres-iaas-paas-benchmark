#!/usr/bin/env bash
# Aggregates the per-run output pulled locally by run-benchmark.sh
# (results/<environment>/<run-id>/) into results/<environment>/summary.csv:
# pgbench throughput and latency, plus the Azure Monitor metrics that say
# whether the run was taken in a bursting or a steady state.
#
# Usage: collect-results.sh <environment>
#
# RUN THIS BEFORE terraform destroy. Azure serves no metrics for a deleted
# resource, so once the environment is gone the credit/CPU columns can never be
# filled in for those runs — the pgbench numbers survive, the context does not.
#
# Runs recorded with --burn-in are skipped: they exist to drain disk burst
# credits, not to be measured.
#
# Waiting a few minutes after the last run before collecting is fine and even
# preferable — Azure Monitor ingestion lags by a couple of minutes, so a
# too-eager query can return a partially filled window.
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
  rid="$(grep -E '^METRICS_RESOURCE_ID=' "$meta" | cut -d= -f2-)"
  if [ -n "$rid" ]; then
    METRIC_COLUMNS="$(metric_columns_for "$rid" || true)"
    break
  fi
done

if [ -z "$METRIC_COLUMNS" ]; then
  echo "NOTE: no run under $RESULTS_DIR recorded a metrics resource id, so the" >&2
  echo "      CSV carries pgbench columns only. Runs made before metric" >&2
  echo "      collection existed, or after terraform destroy, look like this." >&2
fi

CSV="$RESULTS_DIR/summary.csv"
{
  printf 'run_id,tps,latency_avg_ms'
  while read -r col; do [ -n "$col" ] && printf ',%s' "$col"; done <<<"$METRIC_COLUMNS"
  printf '\n'
} >"$CSV"

counted=0
skipped=0

for run_dir in "$RESULTS_DIR"/*/; do
  run_id="$(basename "$run_dir")"
  summary_file="${run_dir}summary.txt"
  [ -f "$summary_file" ] || continue

  burn_in=false
  metrics_resource_id=""
  if [ -f "${run_dir}meta.env" ]; then
    grep -qE '^BURN_IN=true$' "${run_dir}meta.env" && burn_in=true
    metrics_resource_id="$(grep -E '^METRICS_RESOURCE_ID=' "${run_dir}meta.env" | cut -d= -f2-)"
  fi
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

  # Metric values, keyed by CSV column, for this run's measured window.
  declare -A metric_values=()
  if [ -n "$metrics_resource_id" ] && [ -f "${run_dir}window.env" ]; then
    measure_start=""
    measure_end=""
    # shellcheck disable=SC1091
    source "${run_dir}window.env"
    if [ -n "${MEASURE_START:-}" ] && [ -n "${MEASURE_END:-}" ]; then
      while IFS='=' read -r col val; do
        [ -n "$col" ] && metric_values["$col"]="$val"
      done < <(fetch_metrics "$metrics_resource_id" "$MEASURE_START" "$MEASURE_END")
    else
      echo "WARNING: $run_id has no measured window recorded, metrics left empty" >&2
    fi
    unset MEASURE_START MEASURE_END
  elif [ -n "$METRIC_COLUMNS" ]; then
    echo "WARNING: $run_id predates metric collection, metrics left empty" >&2
  fi

  {
    printf '%s,%s,%s' "$run_id" "$tps" "$latency"
    while read -r col; do
      [ -n "$col" ] && printf ',%s' "${metric_values[$col]-}"
    done <<<"$METRIC_COLUMNS"
    printf '\n'
  } >>"$CSV"

  counted=$((counted + 1))
  unset metric_values
done

echo "Written: $CSV ($counted runs in the dataset, $skipped skipped)"

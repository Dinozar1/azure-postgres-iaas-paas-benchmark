#!/usr/bin/env bash
# Aggregates per-run pgbench summaries already pulled locally by
# run-benchmark.sh (results/<environment>/<run-id>/summary.txt) into a single
# results/<environment>/summary.csv with columns: run_id,tps,latency_avg_ms.
#
# This is the raw material for the statistical plan in CLAUDE.md (mean ± CI
# across N repetitions) — it does not itself compute stats, just collects them.
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

CSV="$RESULTS_DIR/summary.csv"
echo "run_id,tps,latency_avg_ms" >"$CSV"

shopt -s nullglob
for run_dir in "$RESULTS_DIR"/*/; do
  run_id="$(basename "$run_dir")"
  summary_file="${run_dir}summary.txt"
  [ -f "$summary_file" ] || continue

  tps="$(grep -oP '(?<=^tps = )[0-9.]+' "$summary_file" || true)"
  latency="$(grep -oP '(?<=^latency average = )[0-9.]+' "$summary_file" || true)"

  if [ -z "$tps" ] || [ -z "$latency" ]; then
    echo "WARNING: could not parse $summary_file, skipping" >&2
    continue
  fi

  echo "${run_id},${tps},${latency}" >>"$CSV"
done

echo "Written: $CSV"

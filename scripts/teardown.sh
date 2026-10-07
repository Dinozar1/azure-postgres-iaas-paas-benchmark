#!/usr/bin/env bash
# Ends a measurement session for one environment, in the only order that loses
# nothing:
#   1. collect-results.sh, once the Azure Monitor ingestion lag has passed —
#      platform metrics are readable only while the resource still exists
#   2. check that the latest measured run has every required metric column
#      filled (re-collecting a few times for late ingestion); if not, stop
#      BEFORE destroying anything
#   3. gzip the raw per-transaction pgbench logs
#   4. upload results/<environment>/ to the "results" container of the state
#      storage account (created by bootstrap/)
#   5. terraform destroy, then confirm the resource group is really gone
#
# Usage: teardown.sh <environment> [--force]
#   --force  destroy even if step 2 finds empty metric columns. They then stay
#            empty for good, so this has to be a deliberate choice.
#
# A failed upload does not block the destroy: the results are still on disk,
# and leaving the environment running is the costlier failure. Re-running is
# safe — collected metrics are cached per run, gzip skips compressed logs, the
# upload overwrites, and destroying an empty state is a no-op.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

[ $# -ge 1 ] || usage_env_arg
ENV_NAME="$1"
shift
require_env_dir "$ENV_NAME"

FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
  --force) FORCE=true ;;
  *)
    echo "Unknown option: $1" >&2
    usage_env_arg
    ;;
  esac
  shift
done

METRIC_CHECK_ATTEMPTS=3
METRIC_CHECK_RETRY_SECONDS=120
# Retrying only makes sense when the outcome decides whether to destroy.
$FORCE && METRIC_CHECK_ATTEMPTS=1

RESULTS_DIR="$RESULTS_ROOT/$ENV_NAME"
RG_NAME="rg-$(tfvar "$ENV_DIR" environment_name)"

# The newest run that goes into the dataset (not a burn-in), or empty.
latest_measured_run() {
  local dir run_id last=""
  for dir in "$RESULTS_DIR"/*/; do
    [ -f "${dir}summary.txt" ] || continue
    run_id="$(basename "$dir")"
    [[ "$run_id" == burnin-* ]] && continue
    [ "$(env_get "${dir}meta.env" BURN_IN)" = true ] && continue
    last="$dir"
  done
  printf '%s' "$last"
}

# Prints the required metric columns that are empty for the run in
# summary.csv (or a note if the run is missing from it); prints nothing when
# all are filled.
empty_required_columns() {
  local run_dir="$1" rid
  rid="$(env_get "${run_dir}meta.env" METRICS_RESOURCE_ID)"
  if [ -z "$rid" ]; then
    echo "WARNING: $(basename "$run_dir") recorded no metrics resource id; nothing to check" >&2
    return 0
  fi
  python3 - "$RESULTS_DIR/summary.csv" "$(basename "$run_dir")" \
    "$(metric_required_columns_for "$rid" | tr '\n' ' ')" <<'PY'
import csv, sys

path, run_id, required = sys.argv[1], sys.argv[2], sys.argv[3].split()
with open(path, newline="") as f:
    row = next((r for r in csv.DictReader(f) if r["run_id"] == run_id), None)
if row is None:
    print("(run missing from summary.csv)")
else:
    for col in required:
        if not row.get(col):
            print(col)
PY
}

upload_results() {
  local key
  key="$(az storage account keys list --resource-group "$RESULTS_STORAGE_RG" \
    --account-name "$RESULTS_STORAGE_ACCOUNT" --query '[0].value' -o tsv)" || return 1
  # Key via the environment rather than --account-key, so it never shows up in
  # the process list.
  AZURE_STORAGE_ACCOUNT="$RESULTS_STORAGE_ACCOUNT" AZURE_STORAGE_KEY="$key" \
    az storage blob upload-batch --auth-mode key \
    --destination "$RESULTS_CONTAINER" --destination-path "$ENV_NAME" \
    --source "$RESULTS_DIR" --overwrite true --only-show-errors -o none
}

shopt -s nullglob

if [ -d "$RESULTS_DIR" ]; then
  # --- 1 + 2: collect, then verify the latest run's metrics -----------------
  last_run="$(latest_measured_run)"
  if [ -n "$last_run" ]; then
    measure_end="$(env_get "${last_run}window.env" MEASURE_END)"
    if [ -n "$measure_end" ]; then
      wait_s=$(($(iso_to_epoch "$measure_end") + METRIC_INGESTION_LAG_SECONDS - $(date +%s)))
      if [ "$wait_s" -gt 0 ]; then
        echo "== waiting ${wait_s}s for Azure Monitor to ingest the end of $(basename "$last_run") =="
        sleep "$wait_s"
      fi
    fi

    attempt=1
    while :; do
      echo "== collect-results.sh $ENV_NAME (attempt $attempt/$METRIC_CHECK_ATTEMPTS) =="
      "$SCRIPT_DIR/collect-results.sh" "$ENV_NAME"
      empty="$(empty_required_columns "$last_run")"
      [ -z "$empty" ] && break
      echo "Empty metric columns for $(basename "$last_run"):" $empty >&2
      if [ "$attempt" -ge "$METRIC_CHECK_ATTEMPTS" ]; then
        if $FORCE; then
          echo "WARNING: --force given, destroying anyway; these columns stay empty for good." >&2
          break
        fi
        echo "ABORTED before terraform destroy — $ENV_NAME IS STILL RUNNING AND BILLING." >&2
        echo "Fix the metric collection and re-run, or accept the gaps with:" >&2
        echo "  $0 $ENV_NAME --force" >&2
        exit 1
      fi
      attempt=$((attempt + 1))
      echo "   retrying in ${METRIC_CHECK_RETRY_SECONDS}s (late ingestion is the usual cause)" >&2
      sleep "$METRIC_CHECK_RETRY_SECONDS"
    done
  else
    echo "NOTE: no measured run for $ENV_NAME, nothing to collect or check."
  fi

  # --- 3: compress raw per-transaction logs ---------------------------------
  raw_logs=()
  while IFS= read -r -d '' f; do raw_logs+=("$f"); done \
    < <(find "$RESULTS_DIR" -type f -name 'pgbench_log.*' ! -name '*.gz' -print0)
  if [ ${#raw_logs[@]} -gt 0 ]; then
    echo "== gzip ${#raw_logs[@]} raw pgbench log(s) =="
    gzip "${raw_logs[@]}"
  fi

  # --- 4: archive ------------------------------------------------------------
  echo "== upload $RESULTS_DIR -> $RESULTS_STORAGE_ACCOUNT/$RESULTS_CONTAINER/$ENV_NAME/ =="
  if ! upload_results; then
    echo "WARNING: upload failed; results remain in $RESULTS_DIR." >&2
    echo "         Destroying anyway — re-run $0 $ENV_NAME later to retry the upload." >&2
  fi
else
  echo "NOTE: no results directory for $ENV_NAME, nothing to collect or upload."
fi

# --- 5: destroy and verify ---------------------------------------------------
echo "== terraform destroy ($ENV_NAME) =="
terraform -chdir="$ENV_DIR" destroy -auto-approve -input=false

if [ "$(az group exists --name "$RG_NAME")" != false ]; then
  echo "ERROR: resource group $RG_NAME still exists after destroy — check the portal." >&2
  exit 1
fi
echo "Done: $ENV_NAME destroyed, resource group $RG_NAME is gone."

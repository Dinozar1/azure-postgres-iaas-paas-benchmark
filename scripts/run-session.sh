#!/usr/bin/env bash
# One unattended measurement session for an environment, start to finish:
#   1. admin_source_ip in the environment's terraform.tfvars set to the
#      current public IP (the NSG admits SSH from that address only)
#   2. terraform init + apply
#   3. wait for cloud-init to finish on the client VM, and on the database VM
#      for IaaS
#   4. init-db.sh
#   5. run-benchmark.sh --burn-in (burn-in, then the first repetition with no
#      idle time between), then the remaining repetitions back to back
#   6. teardown.sh (collect, check metrics, archive, terraform destroy)
#
# Usage: run-session.sh <environment> <repetitions> [--phase pilot|main]
#   --phase  marks every run of the session (default pilot: only runs
#            explicitly marked main make the final dataset)
#
# Nothing may be left running: a trap runs teardown.sh --force on any error,
# on Ctrl+C (SIGINT), SIGTERM and SIGHUP (the terminal closing), and a second
# Ctrl+C cannot interrupt that teardown. Still, run long sessions inside tmux
# or screen. If the regular teardown.sh refuses to destroy (empty metric
# columns), the trap destroys with --force as well — a lost metric is cheaper
# than an environment billing overnight.
#
# The whole session is logged to results/<environment>/session-<timestamp>.log.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  echo "Usage: $(basename "$0") <environment> <repetitions> [--phase pilot|main]" >&2
  echo "  environment: one of $VALID_ENVIRONMENTS" >&2
  exit 1
}

[ $# -ge 2 ] || usage
ENV_NAME="$1"
REPETITIONS="$2"
shift 2
require_env_dir "$ENV_NAME"
[[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || {
  echo "repetitions must be a positive integer, got: $REPETITIONS" >&2
  exit 1
}

PHASE=pilot
while [ $# -gt 0 ]; do
  case "$1" in
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
if [[ " $VALID_PHASES " != *" $PHASE "* ]]; then
  echo "Unknown phase: $PHASE (valid: $VALID_PHASES)" >&2
  exit 1
fi

mkdir -p "$RESULTS_ROOT/$ENV_NAME"
LOG="$RESULTS_ROOT/$ENV_NAME/session-$(date -u +%Y%m%dT%H%M%SZ).log"
# tee has to outlive the signals the trap below handles: Ctrl+C reaches the
# whole process group, and with tee dead the trap's first echo would raise
# SIGPIPE and kill the script before its teardown. bash resets SIGINT to the
# default on exec even after trap '' INT, hence tee -i (ignore interrupts).
exec > >(trap '' TERM HUP; exec tee -i -a "$LOG") 2>&1

# The log's last lines are written after teardown.sh has archived results/,
# so the log goes up once more on its own at the very end. Best effort.
upload_session_log() {
  local key
  key="$(az storage account keys list --resource-group "$RESULTS_STORAGE_RG" \
    --account-name "$RESULTS_STORAGE_ACCOUNT" --query '[0].value' -o tsv 2>/dev/null)" || return 1
  AZURE_STORAGE_ACCOUNT="$RESULTS_STORAGE_ACCOUNT" AZURE_STORAGE_KEY="$key" \
    az storage blob upload --auth-mode key --container-name "$RESULTS_CONTAINER" \
    --name "$ENV_NAME/$(basename "$LOG")" --file "$LOG" --overwrite true --only-show-errors -o none
}

SESSION_DONE=false
on_exit() {
  local rc=$?
  # Nothing in here may stop the teardown: no errexit, no death by SIGPIPE
  # if the output has gone, no second Ctrl+C. teardown.sh itself gets the
  # default SIGPIPE back, but keeps ignoring INT/TERM/HUP.
  set +e
  trap - EXIT
  trap '' INT TERM HUP PIPE
  if ! $SESSION_DONE; then
    echo
    echo "!! session for $ENV_NAME aborted (exit status $rc) — teardown.sh --force"
    if ! (trap - PIPE; exec "$SCRIPT_DIR/teardown.sh" "$ENV_NAME" --force); then
      echo "!! TEARDOWN FAILED — resources may still be running and billing." >&2
      echo "!! Check resource group rg-$(tfvar "$ENV_DIR" environment_name) now." >&2
    fi
  fi
  echo "== session log: $LOG =="
  upload_session_log >/dev/null 2>&1 || echo "WARNING: session log not uploaded; it is at $LOG" >&2
  exit "$rc"
}
on_signal() {
  set +e
  trap '' PIPE
  echo
  echo "!! $2"
  exit "$1"
}
trap on_exit EXIT
trap 'on_signal 130 interrupted' INT
trap 'on_signal 143 terminated' TERM
trap 'on_signal 129 "hung up"' HUP

# wait_for_cloud_init <public_ip> <label>
wait_for_cloud_init() {
  local ip="$1" label="$2" i status
  for i in $(seq 1 30); do
    ssh "${SSH_OPTS[@]}" -o BatchMode=yes "${SSH_USER}@${ip}" true 2>/dev/null && break
    [ "$i" -eq 30 ] && {
      echo "ERROR: $label ($ip) not reachable over SSH after 5 minutes" >&2
      return 1
    }
    sleep 10
  done
  status="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "cloud-init status --wait --long" 2>/dev/null || true)"
  if ! grep -q '^status: done' <<<"$status"; then
    echo "ERROR: cloud-init on $label ($ip) did not finish cleanly:" >&2
    echo "$status" >&2
    return 1
  fi
  echo "   cloud-init done on $label"
}

echo "== session $ENV_NAME: $REPETITIONS repetition(s), phase $PHASE, started $(now_iso) =="

echo "== 1. admin_source_ip =="
IP="$(curl -s --max-time 10 ifconfig.me || true)"
if [[ ! "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  echo "ERROR: could not determine the current public IP (got: '$IP')" >&2
  exit 1
fi
sed -i -E "s|^(admin_source_ip[[:space:]]*=[[:space:]]*)\"[^\"]*\"|\1\"$IP/32\"|" "$ENV_DIR/terraform.tfvars"
echo "   $(grep -E '^admin_source_ip' "$ENV_DIR/terraform.tfvars")"

echo "== 2. terraform apply =="
terraform -chdir="$ENV_DIR" init -input=false
terraform -chdir="$ENV_DIR" apply -auto-approve -input=false

echo "== 3. cloud-init =="
wait_for_cloud_init "$(tf_output "$ENV_DIR" client_vm_public_ip)" "client VM"
case "$ENV_NAME" in
iaas-*) wait_for_cloud_init "$(tf_output "$ENV_DIR" db_vm_public_ip)" "database VM" ;;
esac

echo "== 4. init-db =="
"$SCRIPT_DIR/init-db.sh" "$ENV_NAME"

echo "== 5. repetitions =="
echo "-- repetition 1/$REPETITIONS (after burn-in) --"
"$SCRIPT_DIR/run-benchmark.sh" "$ENV_NAME" --burn-in --phase "$PHASE"
for i in $(seq 2 "$REPETITIONS"); do
  echo "-- repetition $i/$REPETITIONS --"
  "$SCRIPT_DIR/run-benchmark.sh" "$ENV_NAME" --phase "$PHASE"
done

echo "== 6. teardown =="
"$SCRIPT_DIR/teardown.sh" "$ENV_NAME"
SESSION_DONE=true

echo "== session $ENV_NAME finished $(now_iso): $RESULTS_ROOT/$ENV_NAME/summary.csv =="

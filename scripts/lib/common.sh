# Shared config and helpers for scripts/*.sh. Sourced, not executed directly.
set -euo pipefail

# --- pgbench parameters (fixed by thesis methodology — see CLAUDE.md) ---
PGBENCH_SCALE=1000
WARMUP_SECONDS=120
MEASURE_SECONDS=720
PGBENCH_CLIENTS=25
PGBENCH_JOBS=2
PROGRESS_INTERVAL=60
DB_PORT=5432

# RSA, not ed25519: the azurerm 3.x provider rejects ed25519 in admin_ssh_key.
SSH_KEY="$HOME/.ssh/id_rsa_pgbench"
SSH_USER="azureuser"
# ServerAlive* keeps long, quiet operations alive: pgbench -i at scale 1000
# prints nothing for tens of minutes, long enough for a NAT/firewall idle
# timeout to drop the session and kill the run.
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10
  -o ServerAliveInterval=30 -o ServerAliveCountMax=10)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_ROOT="$REPO_ROOT/results"

VALID_ENVIRONMENTS="iaas-standard-ssd iaas-premium-ssd paas-burstable paas-general-purpose"

usage_env_arg() {
  echo "Usage: $(basename "$0") <environment>" >&2
  echo "  environment: one of $VALID_ENVIRONMENTS" >&2
  exit 1
}

# Sets the ENV_DIR global. Exits with an error on an unknown environment name
# (called directly, not via command substitution, so exit actually stops the script).
require_env_dir() {
  local env="$1"
  ENV_DIR="$REPO_ROOT/environments/$env"
  if [ ! -d "$ENV_DIR" ]; then
    echo "Unknown environment: $env" >&2
    echo "Valid: $VALID_ENVIRONMENTS" >&2
    exit 1
  fi
}

tf_output() {
  local env_dir="$1" name="$2"
  terraform -chdir="$env_dir" output -raw "$name"
}

tfvar() {
  local env_dir="$1" name="$2"
  grep -E "^${name}[[:space:]]*=" "$env_dir/terraform.tfvars" | sed -E 's/^[^=]+=[[:space:]]*"(.*)"[[:space:]]*$/\1/'
}

# Resolves DB connection target for a given environment: sets DB_HOST, DB_USER,
# DB_PASSWORD, DB_NAME globals.
resolve_db_target() {
  local env="$1" env_dir="$2"
  case "$env" in
  iaas-*)
    # "postgres" / "pgbench_db" are hardcoded in modules/iaas-vm/cloud-init.tpl
    # (no Terraform variable backs them there), so they're hardcoded here too —
    # keep both in sync if the cloud-init template ever changes.
    DB_HOST="$(tf_output "$env_dir" db_vm_private_ip)"
    DB_USER="postgres"
    DB_NAME="pgbench_db"
    ;;
  paas-*)
    DB_HOST="$(tf_output "$env_dir" db_fqdn)"
    DB_USER="$(tf_output "$env_dir" db_admin_login)"
    DB_NAME="$(tf_output "$env_dir" db_name)"
    ;;
  *)
    echo "Cannot determine DB target for environment: $env" >&2
    exit 1
    ;;
  esac
  DB_PASSWORD="$(tfvar "$env_dir" postgres_admin_password)"
}

# Escapes ':' and '\' per the .pgpass file format.
pgpass_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g'
}

# Writes a ~/.pgpass on the client VM for the resolved DB target, so that
# pgbench/psql invoked remotely never need the password on a command line or
# in an env var passed through SSH (which would otherwise have to survive
# the remote shell's re-parsing of the whole SSH command string).
push_pgpass() {
  local env_dir="$1"
  local client_ip tmp
  client_ip="$(tf_output "$env_dir" client_vm_public_ip)"
  tmp="$(mktemp)"
  printf '%s:%s:%s:%s:%s\n' \
    "$DB_HOST" "$DB_PORT" "$DB_NAME" \
    "$(pgpass_escape "$DB_USER")" "$(pgpass_escape "$DB_PASSWORD")" >"$tmp"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -q "$tmp" "${SSH_USER}@${client_ip}:.pgpass"
  rm -f "$tmp"
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${client_ip}" "chmod 600 ~/.pgpass"
}

client_vm_scp_from() {
  local env_dir="$1" remote_path="$2" local_path="$3"
  local client_ip
  client_ip="$(tf_output "$env_dir" client_vm_public_ip)"
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -q -r "${SSH_USER}@${client_ip}:${remote_path}" "$local_path"
}

# --- Azure Monitor: confounding-factor metrics -------------------------------
#
# Every SKU in the experiment matrix meters something on a credit balance, so a
# run's throughput depends on state accumulated before it started:
#   - the data disk bursts on IO/BPS credits (full pool at creation, drains
#     under sustained load, refills while idle) — measured at 0 -> 9 -> 17%
#     consumed during the very first trial run, so this is real, not theoretical
#   - Standard_B2s_v2 meters CPU on credits as well, though the first trial run
#     showed the database VM at ~10% CPU with credits accruing, so for this
#     I/O-bound workload CPU is not the binding constraint
#   - the Flexible Server Burstable tier meters CPU the same way
#
# These are collected per run so the analysis can show whether a given
# measurement was taken in a bursting or a steady state, rather than assuming.

# CSV column -> "metric name|aggregation". Aggregation picks the summary that
# matters for that quantity: worst-case remaining credit (Minimum), peak credit
# consumption (Maximum), typical load (Average).
IAAS_METRIC_SPEC=(
  "cpu_pct_avg|Percentage CPU|average"
  "cpu_pct_max|Percentage CPU|maximum"
  "cpu_credits_remaining_min|CPU Credits Remaining|minimum"
  "disk_burst_io_pct_max|Data Disk Used Burst IO Credits Percentage|maximum"
  "disk_burst_bps_pct_max|Data Disk Used Burst BPS Credits Percentage|maximum"
)

# Flexible Server publishes a different, lowercase metric set. These names are
# the intended ones but have NOT yet been verified against a live server (no
# PaaS environment has been deployed at the time of writing) — fetch_metrics
# intersects this list with what the resource actually reports and warns about
# whatever is missing, so an unverified name degrades to an empty column rather
# than failing the run. Confirm with:
#   az monitor metrics list-definitions --resource <server-id> -o table
PAAS_METRIC_SPEC=(
  "cpu_pct_avg|cpu_percent|average"
  "cpu_pct_max|cpu_percent|maximum"
  "cpu_credits_remaining_min|cpu_credits_remaining|minimum"
  "memory_pct_max|memory_percent|maximum"
  "iops_avg|iops|average"
  "storage_pct_max|storage_percent|maximum"
)

# Echoes the metric spec lines appropriate for a resource id.
metric_spec_for() {
  local resource_id="$1"
  case "$resource_id" in
  *"/providers/Microsoft.DBforPostgreSQL/flexibleServers/"*)
    printf '%s\n' "${PAAS_METRIC_SPEC[@]}"
    ;;
  *"/providers/Microsoft.Compute/virtualMachines/"*)
    printf '%s\n' "${IAAS_METRIC_SPEC[@]}"
    ;;
  *)
    echo "Unrecognised resource type for metrics: $resource_id" >&2
    return 1
    ;;
  esac
}

# fetch_metrics <resource_id> <start_iso> <end_iso>
#
# Prints "column=value" lines for the metrics defined for that resource type,
# reduced over the window. Columns whose metric the resource does not publish,
# or which returned no data points, are printed empty. Never fails the caller:
# a missing metric must not cost a completed 12-minute measurement.
fetch_metrics() {
  local resource_id="$1" start_iso="$2" end_iso="$3"
  local spec available names=() seen=()

  spec="$(metric_spec_for "$resource_id")" || return 0

  available="$(az monitor metrics list-definitions --resource "$resource_id" \
    --query "[].name.value" -o tsv 2>/dev/null || true)"
  if [ -z "$available" ]; then
    echo "WARNING: no metric definitions readable for $resource_id (deleted resource?)" >&2
    while IFS='|' read -r col _ _; do [ -n "$col" ] && echo "${col}="; done <<<"$spec"
    return 0
  fi

  # Unique metric names that the resource actually publishes.
  while IFS='|' read -r col metric _; do
    [ -n "$metric" ] || continue
    if ! grep -qxF "$metric" <<<"$available"; then
      echo "WARNING: metric '$metric' not published by this resource, column '$col' left empty" >&2
      continue
    fi
    if [[ ! " ${seen[*]-} " == *" $metric "* ]]; then
      seen+=("$metric")
      names+=("$metric")
    fi
  done <<<"$spec"

  if [ ${#names[@]} -eq 0 ]; then
    while IFS='|' read -r col _ _; do [ -n "$col" ] && echo "${col}="; done <<<"$spec"
    return 0
  fi

  local json
  json="$(az monitor metrics list --resource "$resource_id" \
    --metric "${names[@]}" \
    --start-time "$start_iso" --end-time "$end_iso" \
    --interval PT1M --aggregation Average Maximum Minimum \
    -o json 2>/dev/null || true)"

  if [ -z "$json" ]; then
    echo "WARNING: metric query failed for $resource_id" >&2
    while IFS='|' read -r col _ _; do [ -n "$col" ] && echo "${col}="; done <<<"$spec"
    return 0
  fi

  SPEC="$spec" python3 -c '
import json, os, sys

spec = [l.split("|") for l in os.environ["SPEC"].splitlines() if l.strip()]
data = json.load(sys.stdin)

series = {}
for m in data.get("value", []):
    name = m["name"]["value"]
    pts = []
    for ts in m.get("timeseries", []):
        pts.extend(ts.get("data", []))
    series[name] = pts

def reduce(name, how):
    vals = [p[how] for p in series.get(name, []) if p.get(how) is not None]
    if not vals:
        return ""
    if how == "maximum":
        return f"{max(vals):.2f}"
    if how == "minimum":
        return f"{min(vals):.2f}"
    return f"{sum(vals)/len(vals):.2f}"

for col, name, how in spec:
    print(f"{col}={reduce(name, how)}")
' <<<"$json"
}

# Column order for the aggregated CSV, per resource type.
metric_columns_for() {
  metric_spec_for "$1" | cut -d'|' -f1
}

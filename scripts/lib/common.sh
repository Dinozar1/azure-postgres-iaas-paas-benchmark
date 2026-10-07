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

# Length of the --burn-in load. One standard run (~14 min of load including the
# warm-up) does not drain the data disk's burst-credit pool: the pool lasts
# ~30 min at full burst, and the first trial run used only 17% of it in 12 min.
# 35 minutes of continuous load does.
BURN_IN_SECONDS=2100

# How long Azure Monitor takes to make a platform metric queryable. A query
# over a window that ended more recently than this can come back partially
# filled — and a min/max/avg over a partial window is silently wrong.
METRIC_INGESTION_LAG_SECONDS=300

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

# Archive for raw results (teardown.sh): the "results" container of the same
# storage account that holds Terraform state, both created by bootstrap/.
RESULTS_STORAGE_RG="rg-tfstate-pgbench"
RESULTS_STORAGE_ACCOUNT="sttfstatepgbench01"
RESULTS_CONTAINER="results"

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

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

iso_to_epoch() {
  date -u -d "$1" +%s
}

# env_get <file> <key>: the value of KEY=value in one of the .env files these
# scripts write, or empty if the file or the key is missing.
env_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2- || true
}

# latest_load_end <results_env_dir>: when the most recent load on this
# environment's database ended — init-db.sh or any earlier run, burn-in
# included — or empty if there was none. Disk credits refill only while the
# disk idles, so the gap between this point and the next run's start decides
# how much burst that run begins with. Timestamps are ISO 8601 UTC, so a plain
# sort orders them chronologically; runs from an earlier, destroyed incarnation
# of the environment always precede that incarnation's own init-db.sh.
latest_load_end() {
  local dir="$1"
  {
    grep -hE '^INIT_END=' "$dir"/init-*.env 2>/dev/null || true
    grep -hE '^RUN_END=' "$dir"/*/window.env 2>/dev/null || true
  } | cut -d= -f2- | sort | tail -n1
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

# --- Azure Monitor: USOS metrics and confounding factors ----------------------
#
# Two reasons to pull platform metrics for every measured window:
#
# 1. The USOS description names IOPS, latency and CPU/RAM utilisation as the
#    key metrics. pgbench gives transaction latency; the platform gives disk
#    IOPS, queue depth, CPU and memory, as the hypervisor / managed service
#    sees them.
#
# 2. Every SKU in the experiment matrix meters something on a credit balance,
#    so a run's throughput depends on state accumulated before it started:
#      - the data disk bursts on IO/BPS credits (full pool at creation, drains
#        under sustained load, refills while idle) — measured at 0 -> 9 -> 17%
#        consumed during the very first trial run, so this is real
#      - Standard_B2s_v2 meters CPU on credits as well, though the first trial
#        run (Standard SSD, 128 GB) showed the database VM at ~10% CPU with
#        credits accruing — still to be confirmed on Premium 512 GB, where the
#        faster disk lets the CPU do more work
#      - the Flexible Server Burstable tier meters CPU the same way
#    Collected per run, they let the analysis show whether a measurement was
#    taken in a bursting or a steady state, rather than assume either.
#
# Spec line: "csv column|metric name|aggregation[|optional]". The aggregation
# picks the summary that matters for that quantity: worst case for a remaining
# credit or free memory (minimum), peak (maximum), typical load (average).
# "optional" marks a column that may legitimately stay empty (a metric only
# some tiers or VM generations publish); teardown.sh refuses to destroy an
# environment while any other column of the latest run is still empty.
#
# Column names are shared between IaaS and PaaS wherever the quantity is the
# same, so the four environments' CSVs line up in the analysis.
IAAS_METRIC_SPEC=(
  "cpu_pct_avg|Percentage CPU|average"
  "cpu_pct_max|Percentage CPU|maximum"
  "cpu_credits_remaining_min|CPU Credits Remaining|minimum"
  "mem_available_bytes_min|Available Memory Bytes|minimum"
  "disk_read_iops_avg|Data Disk Read Operations/Sec|average"
  "disk_read_iops_max|Data Disk Read Operations/Sec|maximum"
  "disk_write_iops_avg|Data Disk Write Operations/Sec|average"
  "disk_write_iops_max|Data Disk Write Operations/Sec|maximum"
  "disk_queue_depth_avg|Data Disk Queue Depth|average"
  "disk_latency_ms_avg|Data Disk Latency|average"
  "disk_iops_consumed_pct_avg|Data Disk IOPS Consumed Percentage|average"
  "disk_iops_consumed_pct_max|Data Disk IOPS Consumed Percentage|maximum"
  "vm_uncached_iops_consumed_pct_max|VM Uncached IOPS Consumed Percentage|maximum"
  "disk_burst_io_pct_min|Data Disk Used Burst IO Credits Percentage|minimum"
  "disk_burst_io_pct_max|Data Disk Used Burst IO Credits Percentage|maximum"
  "disk_burst_bps_pct_max|Data Disk Used Burst BPS Credits Percentage|maximum"
)
# Names verified against a live Standard_B2s_v2 VM's metric definitions on
# 2026-10-07 (all support PT1M); the iaas-premium-ssd sanity check the same
# day confirmed Azure fills every one of them for the uncached data disk.
# disk_burst_io_pct_min is the pool state at the start of the window (the used
# share only grows under load), disk_burst_io_pct_max the state at its end.

# Flexible Server publishes its own, lowercase metric set. Every name below was
# verified against a live GP_Standard_D2s_v3 server in belgiumcentral on
# 2026-10-07 (az monitor metrics list-definitions; all support PT1M). Two gaps
# against the VM set: no disk latency metric — on PaaS, I/O latency comes only
# from pg_stat_io with track_io_timing — and no storage burst-credit metric.
# cpu_credits_remaining is published on every tier but only Burstable fills it.
# fetch_metrics still intersects the list with what the resource reports, so a
# name Azure ever drops degrades to an empty column instead of failing a run.
PAAS_METRIC_SPEC=(
  "cpu_pct_avg|cpu_percent|average"
  "cpu_pct_max|cpu_percent|maximum"
  "cpu_credits_remaining_min|cpu_credits_remaining|minimum|optional"
  "memory_pct_max|memory_percent|maximum"
  "iops_avg|iops|average"
  "disk_read_iops_avg|read_iops|average"
  "disk_read_iops_max|read_iops|maximum"
  "disk_write_iops_avg|write_iops|average"
  "disk_write_iops_max|write_iops|maximum"
  "disk_queue_depth_avg|disk_queue_depth|average"
  "disk_iops_consumed_pct_avg|disk_iops_consumed_percentage|average"
  "disk_iops_consumed_pct_max|disk_iops_consumed_percentage|maximum"
  "storage_pct_max|storage_percent|maximum"
)

# Printed per minute for the burn-in window (report_burn_in), to show whether
# the burst-credit pool really is drained before the measured runs start. On
# IaaS the data disk's credit metric shows it directly, with IOPS alongside.
# Flexible Server publishes no storage credit metric and serves most reads
# from a host cache, so there the evidence is IOPS against the provisioned
# baseline (2300 at 512 GiB) and the share of it the disk consumes: IOPS
# above the baseline that later fall back to it mean the pool emptied; a disk
# that never reaches its limit is not the bottleneck, and bursting does not
# affect that configuration. CPU and CPU credits are listed for both arms:
# Standard_B2s_v2 and the Burstable tier run on CPU credits, and the higher
# throughput of a faster disk can make CPU the limit instead.
IAAS_BURN_IN_METRICS=(
  "Data Disk Used Burst IO Credits Percentage"
  "Data Disk Read Operations/Sec"
  "Data Disk Write Operations/Sec"
  "Data Disk IOPS Consumed Percentage"
  "CPU Credits Remaining"
  "Percentage CPU"
)
PAAS_BURN_IN_METRICS=(
  "cpu_credits_remaining"
  "cpu_percent"
  "iops"
  "read_iops"
  "write_iops"
  "disk_iops_consumed_percentage"
)

# Prints "iaas" or "paas" for a metrics resource id.
resource_kind() {
  case "$1" in
  *"/providers/Microsoft.DBforPostgreSQL/flexibleServers/"*) echo paas ;;
  *"/providers/Microsoft.Compute/virtualMachines/"*) echo iaas ;;
  *)
    echo "Unrecognised resource type for metrics: $1" >&2
    return 1
    ;;
  esac
}

# Echoes the metric spec lines appropriate for a resource id.
metric_spec_for() {
  case "$(resource_kind "$1")" in
  paas) printf '%s\n' "${PAAS_METRIC_SPEC[@]}" ;;
  iaas) printf '%s\n' "${IAAS_METRIC_SPEC[@]}" ;;
  *) return 1 ;;
  esac
}

burn_in_metrics_for() {
  case "$(resource_kind "$1")" in
  paas) printf '%s\n' "${PAAS_BURN_IN_METRICS[@]}" ;;
  iaas) printf '%s\n' "${IAAS_BURN_IN_METRICS[@]}" ;;
  *) return 1 ;;
  esac
}

# Column order for the aggregated CSV, per resource type.
metric_columns_for() {
  metric_spec_for "$1" | cut -d'|' -f1
}

# Columns that must be filled before teardown.sh may destroy the environment.
metric_required_columns_for() {
  metric_spec_for "$1" | awk -F'|' '$4 != "optional" { print $1 }'
}

# Names of the metrics a resource publishes, one per line; empty if none are
# readable (e.g. the resource has been deleted).
published_metrics() {
  az monitor metrics list-definitions --resource "$1" \
    --query "[].name.value" -o tsv 2>/dev/null || true
}

# report_burn_in <resource_id> <start_iso> [end_iso]
#
# Prints a per-minute table (Azure Monitor averages) of the burn-in metrics the
# resource publishes over the window — up to now by default — plus a
# read+write IOPS column. Run it only once ingestion has caught up with the end
# of the window (METRIC_INGESTION_LAG_SECONDS). Never fails: the burn-in itself
# has already done its job.
report_burn_in() {
  local rid="$1" start="$2" end="${3:-}" available m metrics=() json
  [ -n "$end" ] || end="$(now_iso)"
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
    echo "NOTE: no burn-in metric to report for $rid"
    return 0
  fi

  json="$(az monitor metrics list --resource "$rid" --metric "${metrics[@]}" \
    --start-time "$start" --end-time "$end" \
    --interval PT1M --aggregation Average -o json 2>/dev/null || true)"
  if [ -z "$json" ]; then
    echo "WARNING: burn-in metric query failed for $rid" >&2
    return 0
  fi
  python3 -c '
import json, sys

cols, rows = [], {}
for m in json.load(sys.stdin).get("value", []):
    name = m["name"]["value"]
    cols.append(name)
    for ts in m.get("timeseries", []):
        for p in ts.get("data", []):
            if p.get("average") is not None:
                rows.setdefault(p["timeStamp"], {})[name] = p["average"]

pairs = [("read_iops", "write_iops"),
         ("Data Disk Read Operations/Sec", "Data Disk Write Operations/Sec")]
sums = [(r, w) for r, w in pairs if r in cols and w in cols]
headers = cols + ["read + write IOPS"] * len(sums)

print("Per-minute averages (Azure Monitor):")
for i, h in enumerate(headers, 1):
    print("  [%d] %s" % (i, h))
print("%-17s" % "time (UTC)" + "".join("%10s" % ("[%d]" % i) for i in range(1, len(headers) + 1)))
for t in sorted(rows):
    r = rows[t]
    vals = [r.get(c) for c in cols]
    vals += [r[a] + r[b] if a in r and b in r else None for a, b in sums]
    print("%-17s" % t.replace("T", " ")[:16]
          + "".join("%10.1f" % v if v is not None else "%10s" % "-" for v in vals))
if not rows:
    print("  no data points yet")
' <<<"$json"
}

# fetch_metrics <resource_id> <start_iso> <end_iso> [raw_json_out]
#
# Prints "column=value" lines for the metrics defined for that resource type,
# reduced over the window. Columns whose metric the resource does not publish,
# or which returned no data points, are printed empty. Never fails the caller:
# a missing metric must not cost a completed 12-minute measurement. With
# raw_json_out, the per-minute series behind the reduced values is saved there.
fetch_metrics() {
  local resource_id="$1" start_iso="$2" end_iso="$3" raw_out="${4:-}"
  local spec available names=() seen=()

  spec="$(metric_spec_for "$resource_id")" || return 0

  available="$(published_metrics "$resource_id")"
  if [ -z "$available" ]; then
    echo "WARNING: no metric definitions readable for $resource_id (deleted resource?)" >&2
    while IFS='|' read -r col _; do [ -n "$col" ] && echo "${col}="; done <<<"$spec"
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
    while IFS='|' read -r col _; do [ -n "$col" ] && echo "${col}="; done <<<"$spec"
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
    while IFS='|' read -r col _; do [ -n "$col" ] && echo "${col}="; done <<<"$spec"
    return 0
  fi
  if [ -n "$raw_out" ]; then printf '%s\n' "$json" >"$raw_out"; fi

  SPEC="$spec" python3 -c '
import json, os, sys

spec = [l.split("|")[:3] for l in os.environ["SPEC"].splitlines() if l.strip()]
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

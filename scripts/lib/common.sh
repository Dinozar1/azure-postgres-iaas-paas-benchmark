# Shared config and helpers for scripts/*.sh. Sourced, not executed directly.
set -euo pipefail

# --- pgbench parameters (fixed by thesis methodology — see CLAUDE.md) ---
PGBENCH_SCALE=1000
# Warm-up before each measured run (CLAUDE.md, "Bursting"): at least
# WARMUP_SECONDS, then on while any pool that drained in the burn-in has not
# read spent again since the warm-up began — the reset between runs runs
# below the disk's baseline and the CPU's, and refills both a little. Where
# nothing drains (General Purpose), the warm-up is exactly WARMUP_SECONDS.
WARMUP_SECONDS=120          # minimum
WARMUP_MAX_SECONDS=2400     # safety limit for an adaptive warm-up (40 min)
WARMUP_CHECK_SECONDS=60     # adaptive warm-up: how often the pools are read
# Measured window: one full checkpoint cycle. checkpoint_timeout is 600 s on
# both arms (Azure's setting, carried over to IaaS), so a 600 s window holds
# exactly one timed checkpoint whatever phase it starts in. init-db.sh checks
# the server's checkpoint_timeout equals this, and summary.csv flags each run
# (checkpoint_aligned: one timed checkpoint, none requested). The pilot used
# 720 s, which held one or two checkpoints depending on phase — on the E20's
# ~500 IOPS that alone moved TPS by ~15%. No CHECKPOINT is forced before the
# window: that would start every run right after a full flush of dirty pages,
# a phase continuous operation never has.
MEASURE_SECONDS=600
PGBENCH_CLIENTS=25
PGBENCH_JOBS=2
PROGRESS_INTERVAL=60
DB_PORT=5432

# Burn-in (CLAUDE.md, "Bursting jako czynnik zakłócający"): the load runs
# until every credit pool that drains under it has drained, and never less
# than BURN_IN_SECONDS — what is measured must be a state the configuration
# can hold indefinitely under this workload. One standard run (~14 min) does
# not drain a data disk's pool, and neither did 35 min: the pool is sized for
# 30 min at the full burst rate, but this workload bursts below that rate, so
# a Premium P20 ran dry only after ~46 min. 60 minutes covers the IaaS disks;
# the Burstable tier's CPU credits take longer and are drained adaptively
# (burn_in_pools).
BURN_IN_SECONDS=3600             # minimum, every configuration
BURN_IN_MAX_SECONDS=14400        # safety limit for an adaptive burn-in (4 h)
BURN_IN_CHECK_SECONDS=300        # adaptive burn-in: how often the pool is read
BURN_IN_DRAIN_MARGIN_SECONDS=600 # adaptive burn-in: load kept on after the
#                                  pool first reads empty, to cover metric lag

# Phases of the campaign (CLAUDE.md, "Plan statystyczny"). Recorded per run in
# meta.env and as the phase column of summary.csv, so pilot runs never enter
# the final dataset. Defaults to pilot: the main phase has to be asked for.
VALID_PHASES="pilot main explanatory"

# Environments outside the main four-configuration matrix (CLAUDE.md,
# "Eksperyment wyjaśniający"). Their runs are always phase explanatory, and
# no other environment's runs may be, so neither can leak into the other.
EXPLANATORY_ENVIRONMENTS="iaas-premium-ssd-readcache"

# default_phase_for <environment>
default_phase_for() {
  if [[ " $EXPLANATORY_ENVIRONMENTS " == *" $1 "* ]]; then echo explanatory; else echo pilot; fi
}

# check_phase <environment> <phase> — exits on a phase the environment may not use.
check_phase() {
  local env="$1" phase="$2" explanatory_env=false
  if [[ " $VALID_PHASES " != *" $phase "* ]]; then
    echo "Unknown phase: $phase (valid: $VALID_PHASES)" >&2
    exit 1
  fi
  [[ " $EXPLANATORY_ENVIRONMENTS " == *" $env "* ]] && explanatory_env=true
  if $explanatory_env && [ "$phase" != explanatory ]; then
    echo "$env is an explanatory experiment: its runs must be phase explanatory" >&2
    exit 1
  fi
  if ! $explanatory_env && [ "$phase" = explanatory ]; then
    echo "phase explanatory is reserved for: $EXPLANATORY_ENVIRONMENTS" >&2
    exit 1
  fi
}

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

VALID_ENVIRONMENTS="iaas-standard-ssd iaas-premium-ssd paas-burstable paas-general-purpose iaas-premium-ssd-readcache"

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

# session_id_for <results_env_dir> <iso_time>
#
# The session a run belongs to: the incarnation of the environment, named by
# the timestamp of the init-db.sh that loaded its data — the newest init-*.env
# that ended at or before the given time. Runs of one session share a
# deployment (host, neighbours) and are not independent, so the session, not
# the run, is the statistical unit (CLAUDE.md, "Jednostka statystyczna: sesja").
session_id_for() {
  local dir="$1" t="$2" f end best="" best_end=""
  for f in "$dir"/init-*.env; do
    [ -f "$f" ] || continue
    end="$(env_get "$f" INIT_END)"
    [ -n "$end" ] || continue
    if [[ ! "$end" > "$t" ]] && [[ -z "$best_end" || "$end" > "$best_end" ]]; then
      best="$f"
      best_end="$end"
    fi
  done
  if [ -n "$best" ]; then basename "$best" .env | sed 's/^init-//'; fi
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
  "cpu_credits_remaining_max|CPU Credits Remaining|maximum"
  "cpu_credits_remaining_first|CPU Credits Remaining|first"
  "cpu_credits_remaining_last|CPU Credits Remaining|last"
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
  "disk_burst_io_pct_first|Data Disk Used Burst IO Credits Percentage|first"
  "disk_burst_io_pct_last|Data Disk Used Burst IO Credits Percentage|last"
  "disk_burst_bps_pct_max|Data Disk Used Burst BPS Credits Percentage|maximum"
)
# Names verified against a live Standard_B2s_v2 VM's metric definitions on
# 2026-10-07 (all support PT1M); the iaas-premium-ssd sanity check the same
# day confirmed Azure fills every one of them for the uncached data disk.
# disk_burst_io_pct_min is the pool state at the start of the window (the used
# share only grows under load), disk_burst_io_pct_max the state at its end.
# *_first / *_last are the first and last per-minute readings in the window:
# their difference says which way a pool was moving during the run, which
# min/max alone cannot (the explanatory environment's criterion needs it).

# Flexible Server publishes its own, lowercase metric set. Every name below was
# verified against a live GP_Standard_D2s_v3 server in belgiumcentral on
# 2026-10-07 (az monitor metrics list-definitions; all support PT1M). Two gaps
# against the VM set: no disk latency metric — on PaaS, I/O latency comes only
# from pg_stat_io with track_io_timing — and no storage burst-credit metric.
# cpu_credits_remaining is published on every tier but only Burstable fills it,
# so it is optional here and required for paas-burstable alone
# (metric_required_columns_for).
# fetch_metrics still intersects the list with what the resource reports, so a
# name Azure ever drops degrades to an empty column instead of failing a run.
PAAS_METRIC_SPEC=(
  "cpu_pct_avg|cpu_percent|average"
  "cpu_pct_max|cpu_percent|maximum"
  "cpu_credits_remaining_min|cpu_credits_remaining|minimum|optional"
  "cpu_credits_remaining_max|cpu_credits_remaining|maximum|optional"
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

# --- Steady-state criterion (CLAUDE.md, "Kryterium ważności przebiegu") ------
#
# Fixed before the pilot. A run that fails it stays in summary.csv, flagged
# steady_state=false; the analysis excludes it and reports it separately. The
# thresholds may be revised only on the evidence of a burn-in's credit curve,
# never on TPS results.
STEADY_DISK_BURST_IO_PCT_MIN=99 # disk pool spent: disk_burst_io_pct_min >= this
STEADY_CPU_CREDITS_MIN=0        # IaaS: CPU not throttled, cpu_credits_remaining_min > this
STEADY_CPU_CREDITS_SPENT_MAX=1  # CPU credits spent: cpu_credits_remaining_max <= this
STEADY_TREND_USED_PCT_TOL=1     # disk pool not draining: used share grew <= this over the window
STEADY_TREND_CREDITS_TOL=0.5    # CPU pool not draining: credits fell <= this over the window

# steady_state <environment> [column=value ...]
#
# Prints, from a run's metric columns: true / false for an environment with a
# criterion; n/a for one that needs none (paas-general-purpose, where the disk
# is not the bottleneck); nothing when the metrics the criterion needs are
# missing, so it cannot be judged. One principle behind every criterion: the
# measured state must be one the configuration holds indefinitely under this
# load — every pool that drains under it is spent. On the main IaaS
# configurations the CPU runs below its baseline once the disk pool is spent,
# so credits > 0 lasts forever there; on B1ms the CPU runs above its baseline,
# so only spent credits are sustainable. The explanatory read-cache
# environment, where it is not known in advance which pools drain, applies the
# principle directly: each pool is either spent or not draining during the run.
steady_state() {
  local env="$1" kv
  local burst_min="" burst_first="" burst_last="" credits_min="" credits_max="" credits_first="" credits_last=""
  shift
  for kv in "$@"; do
    case "$kv" in
    disk_burst_io_pct_min=*) burst_min="${kv#*=}" ;;
    disk_burst_io_pct_first=*) burst_first="${kv#*=}" ;;
    disk_burst_io_pct_last=*) burst_last="${kv#*=}" ;;
    cpu_credits_remaining_min=*) credits_min="${kv#*=}" ;;
    cpu_credits_remaining_max=*) credits_max="${kv#*=}" ;;
    cpu_credits_remaining_first=*) credits_first="${kv#*=}" ;;
    cpu_credits_remaining_last=*) credits_last="${kv#*=}" ;;
    esac
  done
  case "$env" in
  iaas-premium-ssd-readcache)
    [ -n "$burst_min" ] && [ -n "$burst_first" ] && [ -n "$burst_last" ] &&
      [ -n "$credits_max" ] && [ -n "$credits_first" ] && [ -n "$credits_last" ] || return 0
    awk -v bmin="$burst_min" -v bfirst="$burst_first" -v blast="$burst_last" \
      -v cmax="$credits_max" -v cfirst="$credits_first" -v clast="$credits_last" \
      -v bt="$STEADY_DISK_BURST_IO_PCT_MIN" -v bt_tol="$STEADY_TREND_USED_PCT_TOL" \
      -v ct="$STEADY_CPU_CREDITS_SPENT_MAX" -v ct_tol="$STEADY_TREND_CREDITS_TOL" \
      'BEGIN {
        disk_ok = (bmin >= bt) || (blast - bfirst <= bt_tol)
        cpu_ok = (cmax <= ct) || (cfirst - clast <= ct_tol)
        print (disk_ok && cpu_ok) ? "true" : "false"
      }'
    ;;
  iaas-*)
    [ -n "$burst_min" ] && [ -n "$credits_min" ] || return 0
    awk -v b="$burst_min" -v c="$credits_min" \
      -v bt="$STEADY_DISK_BURST_IO_PCT_MIN" -v ct="$STEADY_CPU_CREDITS_MIN" \
      'BEGIN { print (b >= bt && c > ct) ? "true" : "false" }'
    ;;
  paas-burstable)
    [ -n "$credits_max" ] || return 0
    awk -v c="$credits_max" -v ct="$STEADY_CPU_CREDITS_SPENT_MAX" \
      'BEGIN { print (c <= ct) ? "true" : "false" }'
    ;;
  paas-general-purpose) echo "n/a" ;;
  esac
}

# burn_in_pools <environment>
#
# The credit pools an adaptive burn-in watches, one per line:
#   metric|kind|spent_at|mode
# kind is "balance" (remaining credits, falling as the pool drains) or "used"
# (share of the pool spent, rising as it drains); spent_at the reading at
# which the pool counts as spent. mode:
#   until_spent     the pool always drains under this load (B1ms CPU credits):
#                   go on until it is spent
#   while_draining  it may or may not drain (IaaS): go on while it is still
#                   draining — moving toward spent over the last
#                   BURN_IN_TREND_SECONDS — until it is spent or levels out
# Either way the burn-in lasts at least BURN_IN_SECONDS, keeps the load on for
# BURN_IN_DRAIN_MARGIN_SECONDS after a pool first reads spent, and stops at
# BURN_IN_MAX_SECONDS. The General Purpose tier has no pool that drains under
# this load, so it burns in for exactly BURN_IN_SECONDS.
burn_in_pools() {
  case "$1" in
  paas-burstable)
    # Spent at <= 1, not 0: once the credits run out the published metric
    # stays at 1.0 while the CPU is throttled (pilot, 2026-10-09). The same
    # threshold as the steady-state criterion (STEADY_CPU_CREDITS_SPENT_MAX).
    echo "cpu_credits_remaining|balance|1|until_spent"
    ;;
  iaas-*)
    echo "Data Disk Used Burst IO Credits Percentage|used|99|while_draining"
    echo "CPU Credits Remaining|balance|0|while_draining"
    ;;
  esac
}
BURN_IN_TREND_SECONDS=900      # look-back for "still draining"
BURN_IN_TREND_MIN_SPAN=600     # shortest series span a trend is judged on
BURN_IN_TREND_USED_PCT_TOL=1   # "used" pool still draining if it rose by more than this
BURN_IN_TREND_CREDITS_TOL=0.5  # "balance" pool still draining if it fell by more than this

# pool_spec <environment> <metric> — the burn_in_pools line for one metric.
pool_spec() {
  burn_in_pools "$1" | awk -F'|' -v m="$2" '$1 == m'
}

# pool_reads_spent <kind> <value> <spent_at> — exit status 0 if spent.
pool_reads_spent() {
  awk -v v="$2" -v t="$3" -v k="$1" 'BEGIN { exit !(k == "used" ? v >= t : v <= t) }'
}

# burn_in_spent_pools <results_env_dir>
#
# The pools the current incarnation's burn-in ran down to spent, one metric
# name per line — the pools each warm-up has to bring back to spent. Taken
# from the newest burn-in that started after the newest init-db.sh, so a
# destroyed incarnation's burn-in never counts. Empty if there is none.
burn_in_spent_pools() {
  local dir="$1" init_end="" b meta load_start latest=""
  init_end="$( (grep -hE '^INIT_END=' "$dir"/init-*.env 2>/dev/null || true) | cut -d= -f2- | sort | tail -n1)"
  for b in "$dir"/burnin-*/; do
    [ -f "${b}meta.env" ] || continue
    load_start="$(env_get "${b}window.env" LOAD_START)"
    [ -n "$load_start" ] || continue
    [[ -z "$init_end" || ! "$load_start" < "$init_end" ]] || continue
    [[ -z "$latest" || "$b" > "$latest" ]] && latest="$b"
  done
  [ -n "$latest" ] || return 0
  env_get "${latest}meta.env" BURN_IN_SPENT_POOLS | tr ';' '\n' | sed '/^$/d'
}

# metric_trend <resource_id> <metric> <lookback_seconds>
#
# Prints "latest earliest span_seconds latest_timestamp" from the per-minute
# averages of a metric over the look-back window (latest and earliest
# readings, and the time between them), or nothing if there is no data yet.
metric_trend() {
  az monitor metrics list --resource "$1" --metric "$2" \
    --start-time "$(date -u -d "-$(($3 / 60 + 5)) min" +%Y-%m-%dT%H:%M:%SZ)" \
    --interval PT1M --aggregation Average -o json 2>/dev/null | python3 -c '
import json, sys
from datetime import datetime
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
pts = sorted((p["timeStamp"], p["average"]) for m in data.get("value", [])
             for ts in m.get("timeseries", []) for p in ts.get("data", [])
             if p.get("average") is not None)
if pts:
    t = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    span = int(t(pts[-1][0]) - t(pts[0][0]))
    print(pts[-1][1], pts[0][1], span, pts[-1][0])
' || true
}

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

# metric_required_columns_for <resource_id> [environment]
#
# Columns that must be filled before teardown.sh may destroy the environment.
# The Burstable tier's criterion rests on its CPU credits, so there they are
# required although optional for the resource type as a whole.
metric_required_columns_for() {
  metric_spec_for "$1" | awk -F'|' '$4 != "optional" { print $1 }'
  if [ "${2:-}" = paas-burstable ]; then
    printf '%s\n' cpu_credits_remaining_min cpu_credits_remaining_max
  fi
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

# reduce_metrics <resource_id> <metrics_json_file>
#
# Prints "column=value" lines for the resource type's metric spec, reduced
# from a saved `az monitor metrics list` response. Only minutes that carry
# data count: for a minute without data Azure returns no average but a
# minimum of 0.0, which would otherwise pass for a real reading (a run's
# CPU-credit minimum once came out as 0.00 that way). Collection works from
# the saved file, so a fix here applies to past runs too — offline, after the
# resource is gone.
reduce_metrics() {
  local spec
  spec="$(metric_spec_for "$1")" || return 0
  SPEC="$spec" python3 -c '
import json, os, sys

spec = [l.split("|")[:3] for l in os.environ["SPEC"].splitlines() if l.strip()]
try:
    data = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    data = {}

series = {}
for m in data.get("value", []):
    pts = [p for ts in m.get("timeseries", []) for p in ts.get("data", [])
           if p.get("average") is not None]
    series[m["name"]["value"]] = sorted(pts, key=lambda p: p["timeStamp"])

def reduce(name, how):
    pts = series.get(name, [])
    if how in ("first", "last"):
        if not pts:
            return ""
        value = pts[0 if how == "first" else -1]["average"]
        return f"{value:.2f}"
    vals = [p[how] for p in pts if p.get(how) is not None]
    if not vals:
        return ""
    if how == "maximum":
        return f"{max(vals):.2f}"
    if how == "minimum":
        return f"{min(vals):.2f}"
    return f"{sum(vals)/len(vals):.2f}"

for col, name, how in spec:
    print(f"{col}={reduce(name, how)}")
' "$2"
}

# fetch_metrics <resource_id> <start_iso> <end_iso> <raw_json_out>
#
# Queries the metrics defined for the resource type over the window, saves the
# per-minute series to raw_json_out and prints them reduced (reduce_metrics).
# Columns whose metric the resource does not publish, or which returned no
# data points, are printed empty. Never fails the caller: a missing metric
# must not cost a completed measurement. raw_json_out is written
# only from a successful query, so a failed one never overwrites saved data.
fetch_metrics() {
  local resource_id="$1" start_iso="$2" end_iso="$3" raw_out="$4"
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
  printf '%s\n' "$json" >"$raw_out"
  reduce_metrics "$resource_id" "$raw_out"
}

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

SSH_KEY="$HOME/.ssh/id_ed25519_pgbench"
SSH_USER="azureuser"
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

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

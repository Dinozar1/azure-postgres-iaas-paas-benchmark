#!/usr/bin/env bash
# Dry run of the measurement scripts, end to end, with nothing reaching Azure.
#
# Each scenario runs on its own copy of scripts/ with fake ssh, scp,
# terraform, az, psql, pgbench, cloud-init, curl and sleep (tests/dry-run/bin)
# first in PATH, HOME pointed at an empty directory (no Azure login, no real
# SSH key) and the timing constants of scripts/lib/common.sh shrunk from
# minutes to seconds. The fake client VM is a local directory: remote commands
# run there, and "pkill -x pgbench" stops the fake pgbench processes, so do not
# run two dry runs at the same time.
#
# Usage: tests/dry-run/run.sh [scenario ...]    (default: all)
# Scenarios: iaas gp burstable readcache error checkpoint campaign
# The work directory is removed after a clean pass (unless DRYRUN_KEEP=1) and
# kept after a failure.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ALL_SCENARIOS="iaas gp burstable readcache error checkpoint campaign"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/pgbench-dryrun.XXXXXX")"
FAILURES=0

# Minutes become seconds; the measured window stays 600 s, since the fake
# pgbench returns a logged run at once and init-db.sh checks it against
# checkpoint_timeout.
SHRINK=(
  "WARMUP_SECONDS=120:WARMUP_SECONDS=2"
  "WARMUP_MAX_SECONDS=2400:WARMUP_MAX_SECONDS=30"
  "WARMUP_CHECK_SECONDS=60:WARMUP_CHECK_SECONDS=1"
  "BURN_IN_SECONDS=3600:BURN_IN_SECONDS=3"
  "BURN_IN_MAX_SECONDS=14400:BURN_IN_MAX_SECONDS=40"
  "BURN_IN_CHECK_SECONDS=300:BURN_IN_CHECK_SECONDS=1"
  "BURN_IN_DRAIN_MARGIN_SECONDS=600:BURN_IN_DRAIN_MARGIN_SECONDS=2"
  "METRIC_INGESTION_LAG_SECONDS=300:METRIC_INGESTION_LAG_SECONDS=1"
)

pass() { echo "  ok   $1"; }
fail() {
  echo "  FAIL $1"
  FAILURES=$((FAILURES + 1))
}
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# col <csv> <column>: the column's values, one per row.
col() {
  python3 -c 'import csv, sys
for r in csv.DictReader(open(sys.argv[1], newline="")):
    print(r[sys.argv[2]])' "$1" "$2"
}
# all_equal <csv> <column> <value>: every row has that value (and there are rows).
all_equal() { [ "$(col "$1" "$2" | sort -u)" = "$3" ]; }
none_empty() { ! col "$1" "$2" | grep -qx ''; }
rows() { [ "$(col "$1" run_id | wc -l)" -eq "$2" ]; }
distinct() { [ "$(col "$1" "$2" | sort -u | wc -l)" -eq "$3" ]; }
no_fake_pgbench_left() { ! pgrep -x pgbench; }

# sandbox <name> <env...>: a fresh copy of scripts/ with fake environments.
sandbox() {
  local name="$1" env f from to
  shift
  SB="$WORK/$name"
  mkdir -p "$SB/repo" "$SB/home/.ssh" "$SB/remote-home"
  cp -r "$REPO/scripts" "$SB/repo/"
  : >"$SB/home/.ssh/id_rsa_pgbench"
  : >"$SB/calls.log"
  for env in "$@"; do
    mkdir -p "$SB/repo/environments/$env"
    cat >"$SB/repo/environments/$env/terraform.tfvars" <<EOF
environment_name        = "dryrun-$env"
admin_source_ip         = "192.0.2.1/32"
postgres_admin_password = "dry:run\\\\pass"
EOF
  done
  f="$SB/repo/scripts/lib/common.sh"
  for pair in "${SHRINK[@]}"; do
    from="${pair%%:*}"
    to="${pair#*:}"
    grep -q "^$from\b" "$f" || {
      echo "dry run is out of date: '$from' not found in scripts/lib/common.sh" >&2
      exit 1
    }
    sed -i "s/^$from\b/$to/" "$f"
  done
}

# in_sandbox <cmd...>: runs a command against the current sandbox's fakes.
in_sandbox() {
  env HOME="$SB/home" DRYRUN="$SB" PATH="$HERE/bin:$PATH" "$@"
}

# session <env> <N> [options]: run-session.sh in the sandbox; output to session.out.
session() {
  (cd "$SB/repo" && in_sandbox scripts/run-session.sh "$@") >>"$SB/session.out" 2>&1
}

# campaign [options]: run-campaign.sh in the sandbox; output to session.out.
campaign() {
  (cd "$SB/repo" && in_sandbox scripts/run-campaign.sh "$@") >>"$SB/session.out" 2>&1
}

scenario_iaas() {
  echo "== iaas: two sessions of iaas-premium-ssd, 2 runs each"
  sandbox iaas iaas-premium-ssd
  export FAKE_LINEAR='{"Data Disk Used Burst IO Credits Percentage": [100, 100], "CPU Credits Remaining": [50, 50]}'
  check "first session exits 0" session iaas-premium-ssd 2
  check "second session exits 0" session iaas-premium-ssd 2
  unset FAKE_LINEAR
  local csv="$SB/repo/results/iaas-premium-ssd/summary.csv"
  check "summary.csv has 4 runs" rows "$csv" 4
  check "phase defaults to pilot" all_equal "$csv" phase pilot
  check "two distinct session_id values" distinct "$csv" session_id 2
  check "session_id filled" none_empty "$csv" session_id
  check "steady_state true (disk spent, CPU credits > 0)" all_equal "$csv" steady_state true
  check "checkpoint_aligned true (one timed, no requested)" all_equal "$csv" checkpoint_aligned true
  check "adaptive warm-up recorded (warmup_s)" none_empty "$csv" warmup_s
  check "burn-in stopped by the watcher (BURN_IN_STOP=done)" \
    grep -rqx 'BURN_IN_STOP=done' "$SB/repo/results/iaas-premium-ssd" --include=meta.env
  check "burn-in report written" find "$SB/repo/results/iaas-premium-ssd" -name burnin-metrics.txt -size +0
  check "measured window is 600 s (pgbench -T 600 -l)" grep -q 'pgbench.* -T 600 .*-l' "$SB/calls.log"
  check "destroy ran once per session" test "$(grep -c '^\[terraform\] destroy' "$SB/calls.log")" -eq 2
  check "raw logs gzipped" find "$SB/repo/results/iaas-premium-ssd" -name 'pgbench_log.*.gz'
  check "no fake pgbench left running" no_fake_pgbench_left
  in_sandbox python3 "$SB/repo/scripts/summarize.py" iaas-premium-ssd >"$SB/summarize.out" 2>&1 || true
  check "summarize: k=2 sessions with a t interval (df=1)" grep -q 'k=2 .*95% CI (t, df=1)' "$SB/summarize.out"
}

scenario_gp() {
  echo "== gp: paas-general-purpose, 2 runs, --phase main"
  sandbox gp paas-general-purpose
  check "session exits 0" session paas-general-purpose 2 --phase main
  local csv="$SB/repo/results/paas-general-purpose/summary.csv"
  check "summary.csv has 2 runs" rows "$csv" 2
  check "phase main" all_equal "$csv" phase main
  check "steady_state n/a (no criterion for GP)" all_equal "$csv" steady_state n/a
  check "one session_id" distinct "$csv" session_id 1
  check "fixed warm-up: WARMUP_STOP=fixed" grep -rqx 'WARMUP_STOP=fixed' "$SB/repo/results/paas-general-purpose" --include=meta.env
  check "checkpoint_timeout checked at init" grep -qx 'CHECKPOINT_TIMEOUT_S=600' "$SB"/repo/results/paas-general-purpose/init-*.env
  check "no fake pgbench left running" no_fake_pgbench_left
}

scenario_burstable() {
  echo "== burstable: paas-burstable, credits at the 1.0 floor, a requested checkpoint"
  sandbox burstable paas-burstable
  export FAKE_CREDITS=1 FAKE_CHECKPOINTS_REQ=1
  check "session exits 0" session paas-burstable 1
  unset FAKE_CREDITS FAKE_CHECKPOINTS_REQ
  local csv="$SB/repo/results/paas-burstable/summary.csv"
  check "steady_state true (cpu_credits_remaining_max <= 1)" all_equal "$csv" steady_state true
  check "checkpoint_aligned false (requested checkpoint)" all_equal "$csv" checkpoint_aligned false
  check "no fake pgbench left running" no_fake_pgbench_left
}

scenario_readcache() {
  echo "== readcache: explanatory phase enforced"
  sandbox readcache iaas-premium-ssd-readcache
  if session iaas-premium-ssd-readcache 1 --phase main; then fail "--phase main rejected"; else pass "--phase main rejected"; fi
  check "nothing applied after the rejection" test "$(grep -c '^\[terraform\] apply' "$SB/calls.log")" -eq 0
  export FAKE_LINEAR='{"Data Disk Used Burst IO Credits Percentage": [100, 100], "CPU Credits Remaining": [50, 50]}'
  check "session exits 0" session iaas-premium-ssd-readcache 1
  unset FAKE_LINEAR
  local csv="$SB/repo/results/iaas-premium-ssd-readcache/summary.csv"
  check "phase explanatory by default" all_equal "$csv" phase explanatory
  check "steady_state true (pools spent or level)" all_equal "$csv" steady_state true
}

scenario_error() {
  echo "== error: the measured run fails, the trap tears down"
  sandbox error iaas-standard-ssd
  export FAKE_LINEAR='{"Data Disk Used Burst IO Credits Percentage": [100, 100], "CPU Credits Remaining": [50, 50]}'
  export FAKE_PGBENCH_FAIL_T=600
  if session iaas-standard-ssd 2; then fail "session exits non-zero"; else pass "session exits non-zero"; fi
  unset FAKE_LINEAR FAKE_PGBENCH_FAIL_T
  check "trap announced the abort" grep -q 'aborted (exit status' "$SB/session.out"
  check "teardown.sh --force destroyed the environment" grep -q '^\[terraform\] destroy' "$SB/calls.log"
  check "no second repetition after the failure" test "$(grep -c -- '-- repetition' "$SB/session.out")" -eq 1
  check "no fake pgbench left running" no_fake_pgbench_left
}

scenario_checkpoint() {
  echo "== checkpoint: checkpoint_timeout differs from the measured window"
  sandbox checkpoint paas-general-purpose
  export FAKE_CHECKPOINT_TIMEOUT=300
  if session paas-general-purpose 1; then fail "session exits non-zero"; else pass "session exits non-zero"; fi
  unset FAKE_CHECKPOINT_TIMEOUT
  check "init-db names the mismatch" grep -q 'checkpoint_timeout is 300s, the measured window assumes 600s' "$SB/session.out"
  check "no data loaded (no pgbench -i)" test "$(grep -c '^\[pgbench\] -i' "$SB/calls.log")" -eq 0
  check "environment destroyed" grep -q '^\[terraform\] destroy' "$SB/calls.log"
}

scenario_campaign() {
  echo "== campaign: run-campaign.sh over a three-round order"
  sandbox campaign paas-general-purpose iaas-premium-ssd paas-burstable
  mkdir -p "$SB/repo/campaign"
  printf '%s\n' "# test order" "round,position,environment,seed" \
    "1,1,paas-general-purpose,1" "1,2,iaas-premium-ssd,1" "2,1,paas-burstable,1" "3,1,paas-general-purpose,1" \
    >"$SB/repo/campaign/round-order.csv"
  local ledger="$SB/repo/campaign/sessions.csv" stop="$SB/repo/results/.campaign-stop"
  export FAKE_LINEAR='{"Data Disk Used Burst IO Credits Percentage": [100, 100], "CPU Credits Remaining": [50, 50]}' FAKE_CREDITS=1
  check "round 1 exits 0" campaign --last-round 1
  check "ledger: two sessions, both exit 0" test "$(col "$ledger" exit_status | tr '\n' ' ')" = "0 0 "
  check "ledger: session_id recorded" none_empty "$ledger" session_id
  check "ledger: campaign order kept" test "$(col "$ledger" environment | tr '\n' ' ')" = "paas-general-purpose iaas-premium-ssd "
  check "5 runs per session, phase main" all_equal "$SB/repo/results/iaas-premium-ssd/summary.csv" phase main
  check "5 runs per session (count)" rows "$SB/repo/results/iaas-premium-ssd/summary.csv" 5
  check "--last-round 1 left round 2 alone" test ! -e "$SB/repo/results/paas-burstable"
  local applies
  applies="$(grep -c '^\[terraform\] apply' "$SB/calls.log")"
  check "relaunch: nothing left in round 1" campaign --last-round 1
  check "relaunch applied nothing" test "$(grep -c '^\[terraform\] apply' "$SB/calls.log")" -eq "$applies"
  touch "$stop"
  if campaign; then fail "stop file present: refuses to start"; else pass "stop file present: refuses to start"; fi
  rm -f "$stop"
  export FAKE_PGBENCH_FAIL_T=600
  if campaign; then fail "failed session stops the campaign"; else pass "failed session stops the campaign"; fi
  unset FAKE_PGBENCH_FAIL_T
  check "ledger: failure recorded" test "$(col "$ledger" exit_status | tail -1)" != 0
  check "relaunch retries the failed session" campaign --last-round 2
  check "ledger: failure, then the retry succeeded" grep -Eq '^0 0 [1-9][0-9]* 0 $' <<<"$(col "$ledger" exit_status | tr '\n' ' ')"
  export FAKE_CHECKPOINTS_REQ=1
  if campaign; then fail "over 20% checkpoint_aligned=false stops the campaign"; else pass "over 20% checkpoint_aligned=false stops the campaign"; fi
  unset FAKE_CHECKPOINTS_REQ
  check "the session itself is recorded as done" test "$(col "$ledger" exit_status | tail -1)" = 0
  check "the stop names the checkpoint check" grep -q 'checkpoint_aligned check for paas-general-purpose failed' "$SB/session.out"
  in_sandbox python3 "$SB/repo/scripts/summarize.py" paas-general-purpose >"$SB/summarize.out" 2>&1 || true
  check "summarize: share and warning printed" grep -q 'phase=main  checkpoint_aligned=false: 5 of 10 runs (50%)  WARNING' "$SB/summarize.out"
  check "summarize: sensitivity without misaligned runs" grep -q 'without checkpoint_aligned=false (sensitivity)' "$SB/summarize.out"
  unset FAKE_LINEAR FAKE_CREDITS
  check "no fake pgbench left running" no_fake_pgbench_left
}

for tool in ssh scp terraform az psql pgbench cloud-init curl sleep; do
  if [ "$(PATH="$HERE/bin:$PATH" command -v "$tool")" != "$HERE/bin/$tool" ]; then
    echo "fake $tool is not first in PATH — refusing to run" >&2
    exit 1
  fi
done
if pgrep -x pgbench >/dev/null; then
  echo "a process named pgbench is already running here; the dry run would kill it — refusing" >&2
  exit 1
fi

for s in ${*:-$ALL_SCENARIOS}; do
  if [[ " $ALL_SCENARIOS " != *" $s "* ]]; then
    echo "unknown scenario: $s (known: $ALL_SCENARIOS)" >&2
    exit 1
  fi
  "scenario_$s"
done

if [ "$FAILURES" -eq 0 ]; then
  if [ "${DRYRUN_KEEP:-0}" = 1 ]; then
    echo "dry run passed; sandboxes kept in $WORK"
  else
    rm -rf -- "$WORK"
    echo "dry run passed"
  fi
else
  echo "dry run: $FAILURES check(s) failed; sandboxes kept in $WORK (session.out, calls.log)" >&2
  exit 1
fi

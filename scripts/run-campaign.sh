#!/usr/bin/env bash
# Runs the main measurement campaign: one run-session.sh per (round, position)
# of campaign/round-order.csv (draw-campaign.py), in that order and back to
# back, each with REPETITIONS runs and --phase main.
#
# Every session that ends is appended to campaign/sessions.csv: round,
# position, environment, session_id, start, end and exit status — the record
# of when each session actually ran. Sessions with exit status 0 there are
# done and skipped, so the campaign can be stopped and relaunched at any time
# and carries on where it left off. A session that failed stays in the ledger
# with its exit status; summarize.py leaves its runs out of the analysis.
#
# A failed session is retried once, after RETRY_WAIT_SECONDS (run-session.sh
# has already torn it down); a second failure stops the campaign.
#
# --stopping-rule: once every drawn round is done, configurations whose 95% CI
# of mean TPS across sessions is wider than +-5% get one more session each, in
# a new round drawn by draw-campaign.py with seed EXTENSION_SEED_BASE + round,
# until each is within +-5% or has MAX_SESSIONS sessions (CLAUDE.md, "Plan
# kampanii"). The decision is summarize.py --needs-sessions: CI width only.
#
# The campaign stops:
#   - after a session that failed twice in a row;
#   - after a session that leaves over 20% of its configuration's main runs
#     with checkpoint_aligned = false (summarize.py --alignment-check): the
#     agreed sign that the real checkpoint cycle is not the 600 s window;
#   - before the next session, once results/.campaign-stop exists: the
#     graceful way to end it (touch the file; remove it before relaunching);
#   - after the current session on SIGTERM/SIGHUP to this script, or on
#     Ctrl+C, which run-session.sh answers with its own teardown.
#
# Usage: run-campaign.sh [--last-round N | --stopping-rule]
#   default: every round in the file
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

REPETITIONS=5
RETRY_WAIT_SECONDS=600         # pause before the one retry of a failed session
MAX_SESSIONS=6                 # stopping rule: sessions per configuration, at most
EXTENSION_SEED_BASE=20261009   # stopping rule: round r is drawn with seed BASE + r
ORDER="$REPO_ROOT/campaign/round-order.csv"
LEDGER="$REPO_ROOT/campaign/sessions.csv"
STOP_FILE="$RESULTS_ROOT/.campaign-stop"

usage() {
  echo "Usage: $(basename "$0") [--last-round N | --stopping-rule]" >&2
  exit 1
}

LAST_ROUND=0
STOPPING_RULE=false
while [ $# -gt 0 ]; do
  case "$1" in
  --last-round)
    [ $# -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || usage
    LAST_ROUND="$2"
    shift
    ;;
  --stopping-rule) STOPPING_RULE=true ;;
  *) usage ;;
  esac
  shift
done
if $STOPPING_RULE && [ "$LAST_ROUND" -ne 0 ]; then usage; fi

[ -f "$ORDER" ] || {
  echo "No $ORDER — draw the order first (scripts/draw-campaign.py)." >&2
  exit 1
}
if [ -e "$STOP_FILE" ]; then
  echo "$STOP_FILE exists: not starting. Remove it to run the campaign." >&2
  exit 1
fi

# Prints "round position environment" for every scheduled session that has no
# successful entry in the ledger yet, in campaign order.
pending_sessions() {
  python3 - "$ORDER" "$LEDGER" "$LAST_ROUND" <<'PY'
import csv, os, sys
order, ledger, last = sys.argv[1], sys.argv[2], int(sys.argv[3])

def rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(line for line in f if not line.startswith("#")))

done = set()
if os.path.exists(ledger):
    done = {(r["round"], r["position"]) for r in rows(ledger) if r["exit_status"] == "0"}
for r in sorted(rows(order), key=lambda r: (int(r["round"]), int(r["position"]))):
    if last and int(r["round"]) > last:
        continue
    if (r["round"], r["position"]) not in done:
        print(r["round"], r["position"], r["environment"])
PY
}

# order_info last_round | order_info environments — from the drawn order.
order_info() {
  python3 - "$ORDER" "$1" <<'PY'
import csv, sys
with open(sys.argv[1], newline="") as f:
    rows = list(csv.DictReader(line for line in f if not line.startswith("#")))
if sys.argv[2] == "last_round":
    print(max(int(r["round"]) for r in rows))
else:
    print(" ".join(sorted({r["environment"] for r in rows})))
PY
}

# The session_id (init-db.sh timestamp) of the session that ran between
# start and end on env, or empty if it never got as far as loading data.
session_between() {
  local env="$1" start="$2" end="$3" sid init_start
  sid="$(session_id_for "$RESULTS_ROOT/$env" "$end")"
  [ -n "$sid" ] || return 0
  init_start="$(env_get "$RESULTS_ROOT/$env/init-$sid.env" INIT_START)"
  if [[ ! "$init_start" < "$start" ]]; then printf '%s' "$sid"; fi
}

# Deferred while a session runs (bash runs the handler once the foreground
# child has exited), so a signal never cuts a session short from here: the
# session either finishes or tears itself down, and the campaign stops after.
STOP_SIGNAL=""
trap 'STOP_SIGNAL=INT' INT
trap 'STOP_SIGNAL=TERM' TERM
trap 'STOP_SIGNAL=HUP' HUP

stop_requested() {
  [ -n "$STOP_SIGNAL" ] || [ -e "$STOP_FILE" ]
}

# run_slot <round> <position> <env>: the session, retried once if it fails.
# Every attempt goes into the ledger. Returns the last attempt's exit status.
run_slot() {
  local round="$1" position="$2" env="$3" attempt started finished rc=0
  for attempt in 1 2; do
    started="$(now_iso)"
    echo
    echo "== campaign round $round, position $position: $env — attempt $attempt, started $started =="
    rc=0
    "$SCRIPT_DIR/run-session.sh" "$env" "$REPETITIONS" --phase main || rc=$?
    finished="$(now_iso)"
    echo "$round,$position,$env,$(session_between "$env" "$started" "$finished"),$started,$finished,$rc" >>"$LEDGER"
    if [ "$rc" -eq 0 ]; then return 0; fi
    if [ "$attempt" -eq 1 ] && ! stop_requested; then
      echo "!! round $round, position $position ($env) failed with exit status $rc;" \
        "retrying once in ${RETRY_WAIT_SECONDS}s (see the newest results/$env/session-*.log)" >&2
      sleep "$RETRY_WAIT_SECONDS"
      stop_requested && break
    else
      break
    fi
  done
  return "$rc"
}

# Runs every pending session of the drawn order; exits the script on a failure,
# a failed checkpoint_aligned check, a stop file or a signal.
run_pending() {
  local text item round position env rc arc
  local -a pending=()
  # Through a variable, so a failure to read the files stops the script
  # instead of passing for an empty schedule.
  text="$(pending_sessions)"
  [ -z "$text" ] || mapfile -t pending <<<"$text"
  if [ ${#pending[@]} -eq 0 ]; then
    echo "== campaign: nothing pending in the drawn order =="
    return 0
  fi
  echo "== campaign: ${#pending[@]} session(s) to run, $REPETITIONS runs each, phase main, started $(now_iso) =="
  for item in "${pending[@]}"; do
    read -r round position env <<<"$item"
    echo "   round $round, position $position: $env"
  done
  echo "   graceful stop before the next session: touch $STOP_FILE"

  for item in "${pending[@]}"; do
    read -r round position env <<<"$item"
    if [ -e "$STOP_FILE" ]; then
      echo "== $STOP_FILE found: campaign stopped before round $round, position $position ($env) =="
      exit 0
    fi
    rc=0
    run_slot "$round" "$position" "$env" || rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "!! campaign stopped: round $round, position $position ($env) failed with exit status $rc" \
        "$([ -n "$STOP_SIGNAL" ] && echo "after SIG$STOP_SIGNAL" || echo "twice in a row");" \
        "see the newest results/$env/session-*.log. Relaunching retries it." >&2
      exit "$rc"
    fi
    echo "== campaign round $round, position $position: $env done $(now_iso) =="
    arc=0
    python3 "$SCRIPT_DIR/summarize.py" --alignment-check main "$env" || arc=$?
    if [ "$arc" -ne 0 ]; then
      echo "!! campaign stopped after round $round, position $position: checkpoint_aligned check" \
        "for $env failed (exit status $arc) — report before going on." >&2
      exit 3
    fi
    if [ -n "$STOP_SIGNAL" ]; then
      echo "== campaign stopped on SIG$STOP_SIGNAL after round $round, position $position ==" >&2
      exit 1
    fi
  done
}

[ -f "$LEDGER" ] || echo "round,position,environment,session_id,started,finished,exit_status" >"$LEDGER"

ENVIRONMENTS="$(order_info environments)"
while :; do
  run_pending
  $STOPPING_RULE || break

  next=$(($(order_info last_round) + 1))
  if [ "$next" -gt "$MAX_SESSIONS" ]; then
    echo "== stopping rule: round $next would exceed $MAX_SESSIONS sessions per configuration — done =="
    break
  fi
  echo "== stopping rule after round $((next - 1)) (95% CI of mean TPS across sessions, target +-5%) =="
  # Configurations that need another session, one per line; the reasoning goes to stderr.
  needs="$(python3 "$SCRIPT_DIR/summarize.py" --needs-sessions "$MAX_SESSIONS" $ENVIRONMENTS)"
  if [ -z "$needs" ]; then
    echo "== stopping rule: every configuration within +-5% or at $MAX_SESSIONS sessions — done =="
    break
  fi
  if [ -e "$STOP_FILE" ] || [ -n "$STOP_SIGNAL" ]; then
    echo "== campaign stopped before drawing round $next ==" >&2
    exit 0
  fi
  # shellcheck disable=SC2086 # one word per environment
  python3 "$SCRIPT_DIR/draw-campaign.py" --seed $((EXTENSION_SEED_BASE + next)) \
    --first-round "$next" --rounds 1 --envs $needs --out "$ORDER"
done
echo "== campaign: done $(now_iso) =="

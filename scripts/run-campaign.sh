#!/usr/bin/env bash
# Runs the main measurement campaign: one run-session.sh per (round, position)
# of campaign/round-order.csv (draw-campaign.py), in that order and back to
# back, each with REPETITIONS runs and --phase main.
#
# Every session that ends is appended to campaign/sessions.csv: round,
# position, environment, session_id, start, end and exit status — the record
# of when each session actually ran. Sessions with exit status 0 there are
# done and skipped, so the campaign can be stopped and relaunched at any time
# and carries on where it left off.
#
# The campaign stops:
#   - after a session that failed — run-session.sh has already torn it down,
#     and nothing more is spent until someone has looked at what went wrong
#     (relaunching retries that session);
#   - after a session that leaves over 20% of its configuration's main runs
#     with checkpoint_aligned = false (summarize.py --alignment-check): the
#     agreed sign that the real checkpoint cycle is not the 600 s window;
#   - before the next session, once results/.campaign-stop exists: the
#     graceful way to end it (touch the file; remove it before relaunching);
#   - after the current session on SIGTERM/SIGHUP to this script, or on
#     Ctrl+C, which run-session.sh answers with its own teardown.
#
# Usage: run-campaign.sh [--last-round N]   (default: every round in the file)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

REPETITIONS=5
ORDER="$REPO_ROOT/campaign/round-order.csv"
LEDGER="$REPO_ROOT/campaign/sessions.csv"
STOP_FILE="$RESULTS_ROOT/.campaign-stop"

usage() {
  echo "Usage: $(basename "$0") [--last-round N]" >&2
  exit 1
}

LAST_ROUND=0
while [ $# -gt 0 ]; do
  case "$1" in
  --last-round)
    [ $# -ge 2 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || usage
    LAST_ROUND="$2"
    shift
    ;;
  *) usage ;;
  esac
  shift
done

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

# Through a variable, so a failure to read the files stops the script
# instead of passing for an empty schedule.
PENDING_TEXT="$(pending_sessions)"
PENDING=()
[ -z "$PENDING_TEXT" ] || mapfile -t PENDING <<<"$PENDING_TEXT"
if [ ${#PENDING[@]} -eq 0 ]; then
  echo "== campaign: nothing left to run =="
  exit 0
fi
echo "== campaign: ${#PENDING[@]} session(s) to run, $REPETITIONS runs each, phase main, started $(now_iso) =="
for item in "${PENDING[@]}"; do
  read -r round position env <<<"$item"
  echo "   round $round, position $position: $env"
done
echo "   graceful stop before the next session: touch $STOP_FILE"

[ -f "$LEDGER" ] || echo "round,position,environment,session_id,started,finished,exit_status" >"$LEDGER"

for item in "${PENDING[@]}"; do
  read -r round position env <<<"$item"
  if [ -e "$STOP_FILE" ]; then
    echo "== $STOP_FILE found: campaign stopped before round $round, position $position ($env) =="
    exit 0
  fi

  started="$(now_iso)"
  echo
  echo "== campaign round $round, position $position: $env — started $started =="
  rc=0
  "$SCRIPT_DIR/run-session.sh" "$env" "$REPETITIONS" --phase main || rc=$?
  finished="$(now_iso)"
  echo "$round,$position,$env,$(session_between "$env" "$started" "$finished"),$started,$finished,$rc" >>"$LEDGER"

  if [ "$rc" -ne 0 ]; then
    echo "!! campaign stopped: round $round, position $position ($env) failed with exit status $rc;" \
      "see the newest results/$env/session-*.log. Relaunching retries it." >&2
    exit "$rc"
  fi
  echo "== campaign round $round, position $position: $env done $finished =="
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
echo "== campaign: every scheduled session done $(now_iso) =="

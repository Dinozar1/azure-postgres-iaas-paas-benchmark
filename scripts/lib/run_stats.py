#!/usr/bin/env python3
"""Per-run statistics for scripts/collect-results.sh.

Usage:
  run_stats.py --header      print the column names, one per line
  run_stats.py <run_dir>     print column=value lines for one measured run

Reads what run-benchmark.sh pulled back for a run:
  pgbench_log.*[.gz]         per-transaction log (pgbench -l): latency
                             percentiles, failed transactions, and throughput
                             at the start vs the end of the run (drift, e.g. a
                             disk running out of burst credits mid-run)
  pg_stat_*.{before,after}.csv
                             snapshots taken right around the measured run:
                             buffer cache hit ratio, data-file I/O counts and
                             times (track_io_timing), checkpoints
  version.csv                server version
A value that cannot be computed (a file missing, e.g. for a run predating the
snapshots) is printed empty rather than failing the whole collection.
"""
import csv
import glob
import gzip
import math
import os
import re
import sys

COLUMNS = [
    "server_version",
    "lat_p50_ms",
    "lat_p95_ms",
    "lat_p99_ms",
    "lat_p999_ms",
    "failed_tx",
    "tps_first3m",
    "tps_last3m",
    "cache_hit_ratio",
    "io_reads",
    "io_read_time_ms",
    "io_writes",
    "io_write_time_ms",
    "checkpoints_timed",
    "checkpoints_req",
]

PERCENTILES = [("lat_p50_ms", 50), ("lat_p95_ms", 95), ("lat_p99_ms", 99), ("lat_p999_ms", 99.9)]
EDGE_WINDOW_S = 180  # the "first / last 3 minutes" of the measured run
DEFAULT_DURATION_S = 720


def open_text(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def read_rows(path):
    if not os.path.exists(path):
        return None
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def num(value):
    # NULL (empty in psql --csv) marks an operation that does not apply to that
    # pg_stat_io row; for a delta it is the same as zero.
    return float(value) if value not in (None, "") else 0.0


def percentile(sorted_values, p):
    # Nearest-rank: the smallest observation with at least p% of all
    # observations at or below it.
    rank = max(1, math.ceil(p / 100 * len(sorted_values)))
    return sorted_values[rank - 1]


def run_duration(run_dir):
    try:
        with open(os.path.join(run_dir, "summary.txt")) as f:
            m = re.search(r"^duration: (\d+) s", f.read(), re.MULTILINE)
        if m:
            return int(m.group(1))
    except OSError:
        pass
    return DEFAULT_DURATION_S


def transaction_log_stats(run_dir):
    paths = sorted(glob.glob(os.path.join(run_dir, "pgbench_log.*")))
    if not paths:
        return {}
    # pgbench 16, -l without --aggregate-interval, one line per transaction:
    #   client_id transaction_no time script_no time_epoch time_us [...]
    # "time" is the latency in microseconds, or "failed" for a transaction that
    # ended in a serialization or deadlock error ("skipped" exists only with
    # --rate and --latency-limit). time_epoch.time_us is when it finished.
    latencies, finished, failed = [], [], 0
    first_start = None
    for path in paths:
        with open_text(path) as f:
            for line in f:
                fields = line.split()
                if len(fields) < 6:
                    continue
                if not fields[2].isdigit():
                    if fields[2] != "skipped":
                        failed += 1
                    continue
                latency_us = int(fields[2])
                end = int(fields[4]) + int(fields[5]) / 1e6
                start = end - latency_us / 1e6
                if first_start is None or start < first_start:
                    first_start = start
                latencies.append(latency_us)
                finished.append(end)

    out = {"failed_tx": str(failed)}
    if not latencies:
        return out
    latencies.sort()
    for col, p in PERCENTILES:
        out[col] = f"{percentile(latencies, p) / 1000:.3f}"
    # Measured from the start of the earliest transaction, so the first
    # window is not diluted by connection setup.
    first_window_end = first_start + EDGE_WINDOW_S
    last_window_start = first_start + run_duration(run_dir) - EDGE_WINDOW_S
    out["tps_first3m"] = f"{sum(1 for t in finished if t < first_window_end) / EDGE_WINDOW_S:.3f}"
    out["tps_last3m"] = f"{sum(1 for t in finished if t >= last_window_start) / EDGE_WINDOW_S:.3f}"
    return out


def snapshot_pair(run_dir, view):
    before = read_rows(os.path.join(run_dir, f"{view}.before.csv"))
    after = read_rows(os.path.join(run_dir, f"{view}.after.csv"))
    if not before or not after:
        return None
    return before, after


def pg_stat_deltas(run_dir):
    out = {}

    pair = snapshot_pair(run_dir, "pg_stat_database")
    if pair:
        before, after = pair[0][0], pair[1][0]
        hit = num(after["blks_hit"]) - num(before["blks_hit"])
        read = num(after["blks_read"]) - num(before["blks_read"])
        if hit + read > 0:
            out["cache_hit_ratio"] = f"{hit / (hit + read):.6f}"

    # Summed over every backend type, object and context: all data-file I/O
    # the server did during the run, whoever did it (client backends,
    # checkpointer, background writer, autovacuum). WAL is not in pg_stat_io
    # on PostgreSQL 16.
    pair = snapshot_pair(run_dir, "pg_stat_io")
    if pair:
        def key(row):
            return row["backend_type"], row["object"], row["context"]

        before = {key(r): r for r in pair[0]}
        totals = dict.fromkeys(("reads", "read_time", "writes", "write_time"), 0.0)
        for row in pair[1]:
            prev = before.get(key(row), {})
            for col in totals:
                totals[col] += num(row.get(col)) - num(prev.get(col))
        out["io_reads"] = f"{totals['reads']:.0f}"
        out["io_read_time_ms"] = f"{totals['read_time']:.3f}"
        out["io_writes"] = f"{totals['writes']:.0f}"
        out["io_write_time_ms"] = f"{totals['write_time']:.3f}"

    pair = snapshot_pair(run_dir, "pg_stat_bgwriter")
    if pair:
        before, after = pair[0][0], pair[1][0]
        for col in ("checkpoints_timed", "checkpoints_req"):
            out[col] = f"{num(after[col]) - num(before[col]):.0f}"

    return out


def server_version(run_dir):
    rows = read_rows(os.path.join(run_dir, "version.csv"))
    if rows:
        return {"server_version": rows[0]["server_version"]}
    return {}


def main(argv):
    if argv == ["--header"]:
        print("\n".join(COLUMNS))
        return 0
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    run_dir = argv[0]
    values = {}
    values.update(server_version(run_dir))
    values.update(transaction_log_stats(run_dir))
    values.update(pg_stat_deltas(run_dir))
    for col in COLUMNS:
        print(f"{col}={values.get(col, '')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

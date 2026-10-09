#!/usr/bin/env python3
"""Summary statistics for results/<environment>/summary.csv.

Usage: summarize.py <environment-or-summary.csv> [...]

The statistical unit is the SESSION (one deployment of the environment), not
the run: runs of one session share a host and its neighbours, so they are not
independent, and treating them as such would understate the interval (the PaaS
GP pilot session averaged 1383.7 TPS against 1346 in the sanity check a day
earlier, over five times the within-session SD — a hint rather than proof, as
the sanity check ran a shorter burn-in). So, per phase:

  1. mean of the runs within each session,
  2. mean and standard deviation (SD) of those session means,
  3. 95% confidence interval of the mean from Student's t over sessions
     (df = k - 1), also as a percentage of the mean against the campaign's
     +-5% target (CLAUDE.md, "Plan kampanii").

Done twice: over steady-state runs only (steady_state = true, or n/a where a
configuration has no criterion) and over every run, the sensitivity check
reported alongside. Within-session spread is printed as description only.
Every number is labelled, so a spread is never mistaken for an interval.
"""
import csv
import math
import os
import statistics
import sys

METRICS = [("tps", "TPS"), ("latency_avg_ms", "latency [ms]"), ("lat_p99_ms", "p99 [ms]")]
TARGET_PCT = 5.0


def _betacf(a, b, x):
    # Continued fraction for the regularized incomplete beta (Lentz's method).
    tiny, eps = 1e-300, 3e-16
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1.0 / (d if abs(d) > tiny else tiny)
    h = d
    for m in range(1, 300):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > tiny else tiny)
        c = 1.0 + aa / c
        c = c if abs(c) > tiny else tiny
        delta = d * c
        h *= delta
        if abs(delta - 1.0) < eps:
            break
    return h


def _betainc(a, b, x):
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    front = math.exp(math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
                     + a * math.log(x) + b * math.log(1.0 - x))
    if x < (a + 1.0) / (a + b + 2.0):
        return front * _betacf(a, b, x) / a
    return 1.0 - front * _betacf(b, a, 1.0 - x) / b


def t_cdf(t, df):
    p = 0.5 * _betainc(df / 2.0, 0.5, df / (df + t * t))
    return 1.0 - p if t > 0 else p


def t_quantile(q, df):
    """Inverse of Student's t CDF, by bisection (q > 0.5)."""
    lo, hi = 0.0, 1e3
    for _ in range(200):
        mid = (lo + hi) / 2.0
        if t_cdf(mid, df) < q:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2.0


def interval(values):
    """n, mean, SD and the 95% CI half-width (t, df = n - 1) of values."""
    n = len(values)
    mean = statistics.fmean(values)
    if n < 2:
        return n, mean, None, None
    sd = statistics.stdev(values)
    return n, mean, sd, t_quantile(0.975, n - 1) * sd / math.sqrt(n)


def report(rows, indent):
    sessions = {}
    for r in rows:
        sessions.setdefault(r.get("session_id") or "?", []).append(r)
    for sid in sorted(sessions):
        runs = sessions[sid]
        means = []
        for col, name in METRICS:
            vals = [float(r[col]) for r in runs if r.get(col)]
            means.append(f"{name}={statistics.fmean(vals):.2f}" if vals else f"{name}=-")
        print(f"{indent}session {sid}: n={len(runs)} runs, means " + "  ".join(means))
    for col, name in METRICS:
        session_means = []
        within = []
        for runs in sessions.values():
            vals = [float(r[col]) for r in runs if r.get(col)]
            if vals:
                session_means.append(statistics.fmean(vals))
            if len(vals) >= 2:
                within.append(statistics.stdev(vals))
        if not session_means:
            continue
        k, mean, sd, half = interval(session_means)
        line = f"{indent}{name:14} across sessions: k={k}  mean={mean:.2f}"
        if half is None:
            line += "  SD=n/a  95% CI=n/a (needs at least 2 sessions)"
        else:
            pct = 100 * half / mean if mean else float("nan")
            status = "within" if pct <= TARGET_PCT else "WIDER than"
            line += (f"  SD={sd:.2f}  95% CI (t, df={k - 1})=±{half:.2f}"
                     f"  [{mean - half:.2f}, {mean + half:.2f}]  = ±{pct:.1f}% of mean, {status} ±{TARGET_PCT:.0f}%")
        if within:
            line += f"  | within-session SD (mean over sessions, descriptive)={statistics.fmean(within):.2f}"
        print(line)


def load(arg):
    path = arg if arg.endswith(".csv") else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "results", arg, "summary.csv")
    with open(path, newline="") as f:
        return os.path.normpath(path), list(csv.DictReader(f))


def main(args):
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    for arg in args:
        path, rows = load(arg)
        print(f"== {path}")
        for phase in sorted({r.get("phase", "") for r in rows}):
            in_phase = [r for r in rows if r.get("phase", "") == phase]
            steady = [r for r in in_phase if r.get("steady_state") in ("true", "n/a")]
            for label, subset in (("steady-state runs", steady), ("all runs (sensitivity)", in_phase)):
                print(f"  phase={phase or '-'}  {label}:")
                report(subset, "    ")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

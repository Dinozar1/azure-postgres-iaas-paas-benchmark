#!/usr/bin/env python3
"""Summary statistics for results/<environment>/summary.csv.

Usage: summarize.py <environment-or-summary.csv> [...]

For every phase, prints n, mean, standard deviation (SD) and the half-width of
the 95% confidence interval of the mean from Student's t distribution, for
TPS, mean latency and p99 latency — twice: over the steady-state runs only
(steady_state = true, or n/a where a configuration has no criterion), and over
every run, the sensitivity check the analysis reports alongside. Every number
is labelled, so a spread is never mistaken for an interval (CLAUDE.md, "Plan
statystyczny").
"""
import csv
import math
import os
import statistics
import sys

METRICS = [("tps", "TPS"), ("latency_avg_ms", "latency [ms]"), ("lat_p99_ms", "p99 [ms]")]


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


def describe(values):
    n = len(values)
    if n == 0:
        return "n=0"
    mean = statistics.fmean(values)
    if n == 1:
        return f"n=1  mean={mean:.2f}  SD=n/a  95% CI=n/a"
    sd = statistics.stdev(values)
    half = t_quantile(0.975, n - 1) * sd / math.sqrt(n)
    return (f"n={n}  mean={mean:.2f}  SD={sd:.2f}  "
            f"95% CI (t, df={n - 1})=±{half:.2f}  [{mean - half:.2f}, {mean + half:.2f}]")


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
                for col, name in METRICS:
                    vals = [float(r[col]) for r in subset if r.get(col)]
                    print(f"    {name:14} {describe(vals)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

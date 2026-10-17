#!/usr/bin/env python3
"""Final analysis of the measurement campaign: the tables, figures and numbers
of chapter 5.

Usage: analyze.py [--prices analysis/prices-belgiumcentral-<date>.json]

Reads results/<env>/summary.csv (phase main; the read-cache experiment from
phase explanatory) and writes to analysis/:

  results.csv            every metric per configuration: k sessions, mean,
                         SD of the session means, 95% CI (t, df = k - 1)
  cost.csv               the cost model per configuration and the financial
                         efficiency derived from it
  tables/*.tex           LaTeX tabulars (Polish number format) for the thesis
  figures/*.pdf, *.png   figures for the thesis (PDF) and previews (PNG)

Statistics follow summarize.py, which this module imports: the session is
the unit (mean of a session's steady-state runs, then mean, SD and t interval
across sessions), and runs of failed campaign sessions are left out.

Cost model: pay-as-you-go list prices from the snapshot fetch-prices.py
saved (the subscription's own billing lacks PostgreSQL entirely and includes
the test harness), database side only — the server (VM or Flexible Server
compute) and its storage. The client VM, the public IPs used for SSH access
and the network are test harness, not part of what a configuration costs to
run. Standard SSD bills transactions, but since 2023-03-06 only up to an
hourly cap per disk size (E20: 502,000 per hour); the E20 under this
workload does ~500 IOPS, so it always pays the cap. Backup storage up to the
provisioned storage size is included in Flexible Server at no charge, and
the 7-day backups here stay far below 512 GiB.
"""
import argparse
import csv
import glob
import json
import math
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summarize as S  # noqa: E402  (t_quantile, interval, load)

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
OUT = os.path.join(ROOT, "analysis")

# key, label in the thesis, model
CONFIGS = [
    ("paas-general-purpose", "PaaS General Purpose (D2s\\_v3)", "PaaS"),
    ("iaas-premium-ssd", "IaaS Premium SSD P20", "IaaS"),
    ("iaas-standard-ssd", "IaaS Standard SSD E20", "IaaS"),
    ("paas-burstable", "PaaS Burstable (B1ms)", "PaaS"),
]
EXPLANATORY = ("iaas-premium-ssd-readcache", "IaaS Premium SSD P20 + cache odczytu", "IaaS")
PLAIN = {k: re.sub(r"\\_", "_", label) for k, label, _ in CONFIGS + [EXPLANATORY]}
SHORT = {"paas-general-purpose": "PaaS GP", "iaas-premium-ssd": "IaaS P20", "iaas-standard-ssd": "IaaS E20",
         "paas-burstable": "PaaS B1ms", "iaas-premium-ssd-readcache": "IaaS P20 + cache"}

VM_RAM_BYTES = 8 * 2**30          # Standard_B2s_v2: 8 GiB
HOURS_PER_MONTH = 730             # Azure's billing month
STORAGE_GIB = 512                 # every configuration
E20_BILLABLE_TX_PER_HOUR = 502_000  # Standard SSD LRS E20 hourly transaction cap (since 2023-03-06)
E20_CAP_SOURCE = "https://azure.microsoft.com/updates/more-transactions-at-no-additional-cost-for-azure-standard-ssd"


def num(r, col):
    v = r.get(col, "")
    return float(v) if v not in ("", None) else None


def ratio(a, b):
    return a / b if a is not None and b else None


# key, label (Polish), unit, extractor(row) -> value or None
METRICS = [
    ("tps", "przepustowość", "TPS", lambda r: num(r, "tps")),
    ("latency_avg_ms", "latencja średnia", "ms", lambda r: num(r, "latency_avg_ms")),
    ("lat_p50_ms", "latencja p50", "ms", lambda r: num(r, "lat_p50_ms")),
    ("lat_p95_ms", "latencja p95", "ms", lambda r: num(r, "lat_p95_ms")),
    ("lat_p99_ms", "latencja p99", "ms", lambda r: num(r, "lat_p99_ms")),
    ("lat_p999_ms", "latencja p99,9", "ms", lambda r: num(r, "lat_p999_ms")),
    ("read_iops", "IOPS odczytu", "IOPS", lambda r: num(r, "disk_read_iops_avg")),
    ("write_iops", "IOPS zapisu", "IOPS", lambda r: num(r, "disk_write_iops_avg")),
    ("total_iops", "IOPS łącznie", "IOPS",
     lambda r: (num(r, "disk_read_iops_avg") or 0) + (num(r, "disk_write_iops_avg") or 0)
     if num(r, "disk_read_iops_avg") is not None else None),
    ("io_per_tx", "operacje I/O na transakcję", "", lambda r: ratio(
        (num(r, "disk_read_iops_avg") or 0) + (num(r, "disk_write_iops_avg") or 0), num(r, "tps"))
     if num(r, "disk_read_iops_avg") is not None else None),
    ("disk_iops_consumed_pct", "wykorzystanie limitu IOPS dysku", "%", lambda r: num(r, "disk_iops_consumed_pct_avg")),
    ("disk_latency_ms", "latencja dysku (Azure Monitor)", "ms", lambda r: num(r, "disk_latency_ms_avg")),
    ("pg_read_ms", "czas odczytu bloku (pg_stat_io)", "ms", lambda r: ratio(num(r, "io_read_time_ms"), num(r, "io_reads"))),
    ("pg_write_ms", "czas zapisu bloku (pg_stat_io)", "ms", lambda r: ratio(num(r, "io_write_time_ms"), num(r, "io_writes"))),
    ("cache_hit_pct", "trafienia w shared_buffers", "%",
     lambda r: 100 * num(r, "cache_hit_ratio") if num(r, "cache_hit_ratio") is not None else None),
    ("cpu_pct", "CPU (średnio)", "%", lambda r: num(r, "cpu_pct_avg")),
    ("mem_used_pct", "RAM (szczyt)", "%", lambda r: (
        100 * (1 - num(r, "mem_available_bytes_min") / VM_RAM_BYTES) if num(r, "mem_available_bytes_min") is not None
        else num(r, "memory_pct_max"))),
]


def steady(r):
    return r.get("steady_state") in ("true", "n/a")


def session_stats(rows, extract, keep=steady):
    """k, mean, SD, CI half-width and session means of one metric (steady-state runs by default)."""
    sessions = {}
    within = []
    for r in rows:
        if not keep(r):
            continue
        v = extract(r)
        if v is not None:
            sessions.setdefault(r.get("session_id") or "?", []).append(v)
    means = [statistics.fmean(v) for _, v in sorted(sessions.items())]
    if not means:
        return None
    within = [statistics.stdev(v) for v in sessions.values() if len(v) >= 2]
    k, mean, sd, half = S.interval(means)
    return {"k": k, "mean": mean, "sd": sd, "half": half, "session_means": means,
            "n_runs": sum(len(v) for v in sessions.values()),
            "within_sd": statistics.fmean(within) if within else None}


def load_rows_with_failed(env, phase):
    """Like load_rows, but keeps the runs of failed campaign sessions (a sensitivity check only)."""
    with open(os.path.join(ROOT, "results", env, "summary.csv"), newline="") as f:
        return [r for r in csv.DictReader(f) if r.get("phase") == phase]


def burnin_phases(env):
    """Per main-phase burn-in: duration, minute the pool first read spent, mean TPS before / after it."""
    pool = {"paas-burstable": ("cpu_credits_remaining", lambda v: v <= 1)}.get(
        env, ("Data Disk Used Burst IO Credits Percentage", lambda v: v >= 99))
    out = []
    for d in sorted(glob.glob(os.path.join(ROOT, "results", env, "burnin-*"))):
        if not os.path.exists(os.path.join(d, "burnin-azure-metrics.json")) or \
                "PHASE=main" not in open(os.path.join(d, "meta.env")).read():
            continue
        tps, series, start = burnin_series(d)
        pts = [(minutes_between(start, t), v) for t, v in series.get(pool[0], [])]
        spent = next((m for m, v in pts if pool[1](v)), None) if env != "paas-general-purpose" else None
        before = [v for m, v in tps if 3 <= m < (spent if spent else float("inf"))]
        after = [v for m, v in tps if spent is not None and m >= spent + 2]
        out.append({"minutes": tps[-1][0] if tps else None, "spent": spent,
                    "before": statistics.fmean(before) if before else None,
                    "after": statistics.fmean(after) if after else None})
    return out


def load_rows(env, phase):
    _, rows = S.load(env)
    return [r for r in rows if r.get("phase") == phase]


# --- formatting (Polish: decimal comma) ---------------------------------------

def fmt(v, digits):
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return "--"
    s = f"{v:,.{digits}f}".replace(",", " ").replace(".", ",")
    return s.replace(" ", "\\,")


def digits_for(v):
    a = abs(v)
    return 0 if a >= 1000 else 1 if a >= 10 else 2 if a >= 1 else 3


def pm(stat, digits=None):
    if stat is None:
        return "--"
    d = digits if digits is not None else digits_for(stat["mean"])
    if stat["half"] is None:
        return f"{fmt(stat['mean'], d)}"
    return f"{fmt(stat['mean'], d)}\\,$\\pm$\\,{fmt(stat['half'], d)}"


# --- cost model ------------------------------------------------------------------

def cost_model(env, prices, total_iops):
    """[(component, USD per hour)] for one configuration, database side only."""
    p = {k: v["retailPrice"] for k, v in prices.items()}
    per_month = lambda key, qty=1: qty * p[key] / HOURS_PER_MONTH  # noqa: E731
    if env in ("iaas-premium-ssd", "iaas-premium-ssd-readcache"):
        return [("VM Standard_B2s_v2 (Linux)", p["vm_b2s_v2_linux"]),
                ("dysk danych Premium SSD P20 (512 GiB)", per_month("disk_p20")),
                ("dysk systemowy Standard SSD E4", per_month("disk_e4"))]
    if env == "iaas-standard-ssd":
        billable = min(total_iops * 3600, E20_BILLABLE_TX_PER_HOUR)
        return [("VM Standard_B2s_v2 (Linux)", p["vm_b2s_v2_linux"]),
                ("dysk danych Standard SSD E20 (512 GiB)", per_month("disk_e20")),
                ("transakcje dysku E20 (limit godzinowy)", billable / 10_000 * p["disk_e20_operations"]),
                ("dysk systemowy Standard SSD E4", per_month("disk_e4"))]
    if env == "paas-burstable":
        return [("Flexible Server B1ms (compute)", p["pg_burstable_b1ms"]),
                ("storage 512 GiB", per_month("pg_storage", STORAGE_GIB))]
    if env == "paas-general-purpose":
        return [("Flexible Server D2s_v3 (2 vCore)", 2 * p["pg_gp_dsv3_vcore"]),
                ("storage 512 GiB", per_month("pg_storage", STORAGE_GIB))]
    raise ValueError(env)


# --- figures -------------------------------------------------------------------

COLORS = {"IaaS": "#2a78d6", "PaaS": "#eb6834"}   # categorical slots 1-2 (validated)
PCTL = [("lat_p50_ms", "p50", "#86b6ef"), ("lat_p95_ms", "p95", "#2a78d6"), ("lat_p99_ms", "p99", "#104281")]
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e4e3df"


def setup_matplotlib():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({
        "font.size": 9, "axes.titlesize": 9, "axes.labelsize": 9, "xtick.labelsize": 8, "ytick.labelsize": 8.5,
        "legend.fontsize": 8, "axes.edgecolor": INK2, "axes.labelcolor": INK, "xtick.color": INK2,
        "ytick.color": INK, "text.color": INK, "axes.spines.top": False, "axes.spines.right": False,
        "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.6, "axes.axisbelow": True,
        "figure.dpi": 150, "savefig.bbox": "tight", "pdf.fonttype": 42,
    })
    return plt


def comma(x, _pos=None):
    return (f"{x:g}").replace(".", ",")


def save(fig, name):
    os.makedirs(os.path.join(OUT, "figures"), exist_ok=True)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(OUT, "figures", f"{name}.{ext}"), dpi=200 if ext == "png" else None)


def legend_models(ax, loc="lower right"):
    from matplotlib.lines import Line2D
    handles = [Line2D([], [], marker="o", linestyle="", markersize=7, color=COLORS[m], label=m) for m in ("IaaS", "PaaS")]
    ax.legend(handles=handles, loc=loc, frameon=False, handletextpad=0.3)


def fig_tps(plt, stats):
    from matplotlib.ticker import FuncFormatter, LogLocator
    order = sorted(CONFIGS, key=lambda c: stats[c[0]]["tps"]["mean"])
    fig, ax = plt.subplots(figsize=(6.2, 2.5))
    for y, (env, _, model) in enumerate(order):
        s = stats[env]["tps"]
        c = COLORS[model]
        ax.scatter(s["session_means"], [y] * len(s["session_means"]), s=22, facecolors="white", edgecolors=c,
                   linewidths=1.2, zorder=3)
        ax.plot([s["mean"] - s["half"], s["mean"] + s["half"]], [y, y], color=c, linewidth=2.2,
                solid_capstyle="round", zorder=2)
        ax.scatter([s["mean"]], [y], s=46, color=c, zorder=4, edgecolors="white", linewidths=1.2)
        right = max(s["mean"] + s["half"], max(s["session_means"]))
        ax.annotate(f"{fmt(s['mean'], 1)} ± {fmt(s['half'], 1)}".replace("\\,", " "),
                    (right, y), xytext=(9, 0), textcoords="offset points", va="center",
                    fontsize=8, color=INK2)
    ax.set_yticks(range(len(order)), [SHORT[e] for e, _, _ in order])
    ax.set_xscale("log")
    ax.set_xlim(90, 3000)
    ax.xaxis.set_major_locator(LogLocator(base=10, subs=(1, 2, 5)))
    ax.xaxis.set_major_formatter(FuncFormatter(comma))
    ax.xaxis.set_minor_formatter(FuncFormatter(lambda *_: ""))
    ax.set_xlabel("przepustowość [TPS], skala logarytmiczna")
    ax.grid(axis="y", visible=False)
    ax.set_ylim(-0.6, len(order) - 0.4)
    legend_models(ax)
    save(fig, "tps")
    plt.close(fig)


def fig_latency(plt, stats):
    from matplotlib.lines import Line2D
    from matplotlib.ticker import FuncFormatter, LogLocator
    order = sorted(CONFIGS, key=lambda c: stats[c[0]]["lat_p50_ms"]["mean"])
    fig, ax = plt.subplots(figsize=(6.2, 2.4))
    for y, (env, _, _) in enumerate(order):
        vals = [stats[env][key]["mean"] for key, _, _ in PCTL]
        ax.plot([vals[0], vals[-1]], [y, y], color=GRID, linewidth=2, zorder=1)
        for (key, _, color), v in zip(PCTL, vals):
            s = stats[env][key]
            if s["half"]:
                ax.plot([v - s["half"], v + s["half"]], [y, y], color=color, linewidth=2.2, zorder=2,
                        solid_capstyle="round")
            ax.scatter([v], [y], s=40, color=color, zorder=3, edgecolors="white", linewidths=1.2)
    ax.set_yticks(range(len(order)), [SHORT[e] for e, _, _ in order])
    ax.set_xscale("log")
    ax.set_xlim(8, 2000)
    ax.xaxis.set_major_locator(LogLocator(base=10, subs=(1, 2, 5)))
    ax.xaxis.set_major_formatter(FuncFormatter(comma))
    ax.xaxis.set_minor_formatter(FuncFormatter(lambda *_: ""))
    ax.set_xlabel("latencja transakcji [ms], skala logarytmiczna")
    ax.grid(axis="y", visible=False)
    ax.set_ylim(-0.6, len(order) - 0.4)
    ax.legend(handles=[Line2D([], [], marker="o", linestyle="", markersize=7, color=c, label=lbl) for _, lbl, c in PCTL],
              loc="lower right", frameon=False, handletextpad=0.3, ncol=3, columnspacing=1.0)
    save(fig, "latency")
    plt.close(fig)


def fig_cost(plt, cost_rows):
    order = sorted(cost_rows, key=lambda r: r["tx_per_usd_m"])
    fig, ax = plt.subplots(figsize=(6.2, 2.4))
    for y, r in enumerate(order):
        c = COLORS[r["model"]]
        ax.barh(y, r["tx_per_usd_m"], height=0.56, color=c, edgecolor="white", linewidth=2)
        ax.plot([r["tx_per_usd_m_lo"], r["tx_per_usd_m_hi"]], [y, y], color=INK, linewidth=1.4,
                solid_capstyle="butt", zorder=3)
        for x in (r["tx_per_usd_m_lo"], r["tx_per_usd_m_hi"]):
            ax.plot([x, x], [y - 0.1, y + 0.1], color=INK, linewidth=1.4, zorder=3)
        ax.annotate(f"{fmt(r['tx_per_usd_m'], 2)} mln".replace("\\,", " "), (r["tx_per_usd_m_hi"], y),
                    xytext=(6, 0), textcoords="offset points", va="center", fontsize=8, color=INK2)
    ax.set_yticks(range(len(order)), [SHORT[r["env"]] for r in order])
    ax.set_xlabel("transakcje na 1 USD [mln] (cennik pay-as-you-go), z 95% CI")
    ax.xaxis.set_major_formatter(lambda x, _p: comma(x))
    ax.set_xlim(0, max(r["tx_per_usd_m_hi"] for r in order) * 1.22)
    ax.grid(axis="y", visible=False)
    ax.set_ylim(-0.6, len(order) - 0.4)
    legend_models(ax)
    save(fig, "cost-efficiency")
    plt.close(fig)


def burnin_series(burnin_dir):
    """Per-minute TPS from the -P 60 log and the per-minute Azure series, both in minutes since start."""
    tps = []
    with open(os.path.join(burnin_dir, "summary.txt")) as f:
        for line in f:
            m = re.match(r"progress: ([\d.]+) s, ([\d.]+) tps", line)
            if m:
                tps.append((float(m.group(1)) / 60, float(m.group(2))))
    raw = json.load(open(os.path.join(burnin_dir, "burnin-azure-metrics.json")))
    series = {}
    start = None
    for metric in raw["value"]:
        pts = metric["timeseries"][0]["data"] if metric["timeseries"] else []
        series[metric["name"]["value"]] = [(p["timeStamp"], p["average"]) for p in pts if "average" in p]
        if pts and start is None:
            start = pts[0]["timeStamp"]
    return tps, series, start


def minutes_between(t0, t1):
    from datetime import datetime
    f = "%Y-%m-%dT%H:%M:%SZ"
    return (datetime.strptime(t1, f) - datetime.strptime(t0, f)).total_seconds() / 60


def fig_burnin(plt, env, model, burnin_dir):
    tps, series, start = burnin_series(burnin_dir)
    pool = {"iaas-premium-ssd": ("Data Disk Used Burst IO Credits Percentage", "zużyta pula burst dysku [%]"),
            "iaas-standard-ssd": ("Data Disk Used Burst IO Credits Percentage", "zużyta pula burst dysku [%]"),
            "paas-burstable": ("cpu_credits_remaining", "pozostałe kredyty CPU")}.get(env)
    rows = 2 if pool else 1
    fig, axes = plt.subplots(rows, 1, figsize=(6.2, 1.9 * rows), sharex=True, squeeze=False)
    ax = axes[0][0]
    ax.plot([m for m, _ in tps], [v for _, v in tps], color=COLORS[model], linewidth=1.6)
    ax.set_ylabel("TPS")
    ax.set_ylim(0, max(v for _, v in tps) * 1.12)
    ax.yaxis.set_major_formatter(lambda x, _p: comma(x))
    if pool:
        ax2 = axes[1][0]
        pts = series.get(pool[0], [])
        ax2.plot([minutes_between(start, t) for t, _ in pts], [v for _, v in pts], color=INK2, linewidth=1.6,
                 marker="o" if len(pts) < 40 else None, markersize=3.5)
        ax2.set_ylabel(pool[1])
        ax2.yaxis.set_major_formatter(lambda x, _p: comma(x))
        ax2.set_ylim(bottom=0)
    axes[-1][0].set_xlabel("czas od startu burn-inu [min]")
    fig.align_ylabels([a[0] for a in axes])
    save(fig, f"burnin-{env}")
    plt.close(fig)


# --- tables ---------------------------------------------------------------------

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def table(header, rows, align):
    lines = [f"\\begin{{tabular}}{{{align}}}", "\\toprule", " & ".join(header) + " \\\\", "\\midrule"]
    lines += [" & ".join(r) + " \\\\" for r in rows]
    lines += ["\\bottomrule", "\\end{tabular}", ""]
    return "\n".join(lines)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    snapshots = sorted(glob.glob(os.path.join(OUT, "prices-belgiumcentral-*.json")))
    ap.add_argument("--prices", default=snapshots[-1] if snapshots else None)
    args = ap.parse_args(argv)
    if not args.prices:
        sys.exit("no price snapshot: run scripts/fetch-prices.py first")
    snapshot = json.load(open(args.prices))
    prices = snapshot["prices"]

    # --- statistics ---
    stats = {}
    for env, _, _ in CONFIGS + [EXPLANATORY]:
        phase = "explanatory" if env == EXPLANATORY[0] else "main"
        rows = load_rows(env, phase)
        stats[env] = {key: session_stats(rows, fn) for key, _, _, fn in METRICS}

    with open(os.path.join(OUT, "results.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["configuration", "metric", "unit", "k_sessions", "n_runs", "mean", "sd_session_means",
                    "ci95_half", "ci95_low", "ci95_high", "ci95_pct_of_mean", "session_means"])
        for env, _, _ in CONFIGS + [EXPLANATORY]:
            for key, _, unit, _ in METRICS:
                s = stats[env][key]
                if not s:
                    continue
                half = s["half"]
                w.writerow([env, key, unit, s["k"], s["n_runs"], f"{s['mean']:.4f}",
                            "" if s["sd"] is None else f"{s['sd']:.4f}",
                            "" if half is None else f"{half:.4f}",
                            "" if half is None else f"{s['mean'] - half:.4f}",
                            "" if half is None else f"{s['mean'] + half:.4f}",
                            "" if half is None else f"{100 * half / s['mean']:.2f}",
                            " ".join(f"{m:.2f}" for m in s["session_means"])])

    # --- cost ---
    cost_rows = []
    for env, label, model in CONFIGS + [EXPLANATORY]:
        st = stats[env]
        comps = cost_model(env, prices, st["total_iops"]["mean"])
        per_hour = sum(v for _, v in comps)
        tps = st["tps"]
        half = tps["half"] or 0.0
        lo, hi = tps["mean"] - half, tps["mean"] + half
        cost_rows.append({
            "env": env, "label": label, "model": model, "components": comps, "usd_per_hour": per_hour,
            "usd_per_month": per_hour * HOURS_PER_MONTH, "tps": tps["mean"], "tps_half": tps["half"],
            "tx_per_usd_m": tps["mean"] * 3600 / per_hour / 1e6,
            "tx_per_usd_m_lo": lo * 3600 / per_hour / 1e6, "tx_per_usd_m_hi": hi * 3600 / per_hour / 1e6,
            "usd_per_m_tx": per_hour * 1e6 / (tps["mean"] * 3600),
            "usd_per_m_tx_lo": per_hour * 1e6 / (hi * 3600), "usd_per_m_tx_hi": per_hour * 1e6 / (lo * 3600),
        })
    with open(os.path.join(OUT, "cost.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["configuration", "component", "usd_per_hour"])
        for r in cost_rows:
            for name, v in r["components"]:
                w.writerow([r["env"], name, f"{v:.5f}"])
            w.writerow([r["env"], "TOTAL", f"{r['usd_per_hour']:.5f}"])
        w.writerow([])
        w.writerow(["configuration", "usd_per_hour", "usd_per_month_730h", "tps_mean", "tps_ci95_half",
                    "mln_tx_per_usd", "mln_tx_per_usd_low", "mln_tx_per_usd_high",
                    "usd_per_mln_tx", "usd_per_mln_tx_low", "usd_per_mln_tx_high"])
        for r in cost_rows:
            w.writerow([r["env"], f"{r['usd_per_hour']:.5f}", f"{r['usd_per_month']:.2f}", f"{r['tps']:.2f}",
                        "" if r["tps_half"] is None else f"{r['tps_half']:.2f}",
                        f"{r['tx_per_usd_m']:.4f}", f"{r['tx_per_usd_m_lo']:.4f}", f"{r['tx_per_usd_m_hi']:.4f}",
                        f"{r['usd_per_m_tx']:.5f}", f"{r['usd_per_m_tx_lo']:.5f}", f"{r['usd_per_m_tx_hi']:.5f}"])

    # --- tables ---
    tdir = os.path.join(OUT, "tables")
    k_of = lambda env: str(stats[env]["tps"]["k"])  # noqa: E731
    write(os.path.join(tdir, "performance.tex"), table(
        ["Konfiguracja", "$k$", "TPS", "latencja śr. [ms]", "p95 [ms]", "p99 [ms]"],
        [[label, k_of(env), pm(stats[env]["tps"], 1), pm(stats[env]["latency_avg_ms"], 1),
          pm(stats[env]["lat_p95_ms"], 1), pm(stats[env]["lat_p99_ms"], 1)] for env, label, _ in CONFIGS],
        "lrrrrr"))
    write(os.path.join(tdir, "resources.tex"), table(
        ["Konfiguracja", "IOPS odczyt", "IOPS zapis", "I/O na transakcję", "limit IOPS dysku [\\%]", "CPU [\\%]",
         "RAM szczyt [\\%]"],
        [[label, pm(stats[env]["read_iops"], 0), pm(stats[env]["write_iops"], 0), pm(stats[env]["io_per_tx"], 2),
          pm(stats[env]["disk_iops_consumed_pct"], 1), pm(stats[env]["cpu_pct"], 1), pm(stats[env]["mem_used_pct"], 1)]
         for env, label, _ in CONFIGS], "lrrrrrr"))
    write(os.path.join(tdir, "io-latency.tex"), table(
        ["Konfiguracja", "latencja dysku, Azure [ms]", "odczyt bloku, pg\\_stat\\_io [ms]",
         "zapis bloku, pg\\_stat\\_io [ms]", "trafienia w bufor [\\%]"],
        [[label, pm(stats[env]["disk_latency_ms"], 2), pm(stats[env]["pg_read_ms"], 2), pm(stats[env]["pg_write_ms"], 3),
          pm(stats[env]["cache_hit_pct"], 2)] for env, label, _ in CONFIGS], "lrrrr"))
    write(os.path.join(tdir, "cost-components.tex"), table(
        ["Konfiguracja", "Składnik", "USD/h"],
        [[r["label"] if i == 0 else "", name.replace("_", "\\_"), fmt(v, 4)] for r in cost_rows[:len(CONFIGS)]
         for i, (name, v) in enumerate(r["components"])], "llr"))
    write(os.path.join(tdir, "cost-efficiency.tex"), table(
        ["Konfiguracja", "USD/h", "USD/miesiąc", "TPS", "mln transakcji / USD", "USD / mln transakcji"],
        [[r["label"], fmt(r["usd_per_hour"], 4), fmt(r["usd_per_month"], 2), pm(stats[r["env"]]["tps"], 1),
          f"{fmt(r['tx_per_usd_m'], 2)} [{fmt(r['tx_per_usd_m_lo'], 2)}; {fmt(r['tx_per_usd_m_hi'], 2)}]",
          f"{fmt(r['usd_per_m_tx'], 3)} [{fmt(r['usd_per_m_tx_lo'], 3)}; {fmt(r['usd_per_m_tx_hi'], 3)}]"]
         for r in cost_rows[:len(CONFIGS)]], "lrrrrr"))

    # sensitivity: the main analysis against every run, without misaligned runs,
    # and with the runs of failed campaign sessions put back
    sens = []
    for env, label, _ in CONFIGS:
        rows = load_rows(env, "main")
        tps = lambda r: num(r, "tps")  # noqa: E731
        sens.append([label, pm(stats[env]["tps"], 1),
                     pm(session_stats(rows, tps, keep=lambda r: True), 1),
                     pm(session_stats(rows, tps, keep=lambda r: steady(r) and r.get("checkpoint_aligned") != "false"), 1),
                     pm(session_stats(load_rows_with_failed(env, "main"), tps), 1)])
    write(os.path.join(tdir, "sensitivity.tex"), table(
        ["Konfiguracja", "analiza główna", "wszystkie przebiegi", "bez checkpoint\_aligned = false",
         "z sesjami nieudanymi"], sens, "lrrrr"))

    # variance: between sessions (the unit) against within a session (descriptive)
    var_rows = []
    for env, label, _ in CONFIGS:
        s = stats[env]["tps"]
        var_rows.append([label, str(s["k"]), fmt(s["sd"], 1), fmt(100 * s["sd"] / s["mean"], 1),
                         fmt(s["within_sd"], 1), fmt(100 * s["within_sd"] / s["mean"], 1),
                         fmt(s["sd"] / s["within_sd"], 2) if s["within_sd"] else "--"])
    write(os.path.join(tdir, "variance.tex"), table(
        ["Konfiguracja", "$k$", "SD między sesjami", "CV [\\%]", "SD w sesji", "CV [\\%]", "stosunek"],
        var_rows, "lrrrrrr"))

    # explanatory experiment next to the configurations it explains
    expl = []
    for env in ("iaas-premium-ssd", EXPLANATORY[0], "paas-general-purpose"):
        st = stats[env]
        expl.append([PLAIN[env].replace("_", "\\_"), str(st["tps"]["k"]), pm(st["tps"], 1), pm(st["cpu_pct"], 1),
                     pm(st["read_iops"], 0), pm(st["write_iops"], 0), pm(st["disk_iops_consumed_pct"], 1),
                     pm(st["pg_read_ms"], 2)])
    write(os.path.join(tdir, "explanatory.tex"), table(
        ["Konfiguracja", "$k$", "TPS", "CPU [\\%]", "IOPS odczyt", "IOPS zapis", "limit IOPS dysku [\\%]",
         "odczyt bloku [ms]"], expl, "lrrrrrrr"))

    # burn-in phases (descriptive: every main-phase burn-in, the failed attempt's included)
    burn_rows = []
    for env, label, _ in CONFIGS:
        ph = burnin_phases(env)
        spent = [p["spent"] for p in ph if p["spent"] is not None]
        before = [p["before"] for p in ph if p["before"] is not None]
        after = [p["after"] for p in ph if p["after"] is not None]
        mins = [p["minutes"] for p in ph if p["minutes"]]
        rng = lambda v, d=0: (f"{fmt(min(v), d)}--{fmt(max(v), d)}" if v and min(v) != max(v)  # noqa: E731
                              else fmt(v[0], d) if v else "--")
        burn_rows.append([label, str(len(ph)), rng(mins), rng(spent), fmt(statistics.fmean(before), 0) if before else "--",
                          fmt(statistics.fmean(after), 0) if after else "--"])
    write(os.path.join(tdir, "burnin.tex"), table(
        ["Konfiguracja", "burn-iny", "czas [min]", "pula wyczerpana po [min]", "TPS przed", "TPS po"],
        burn_rows, "lrrrrr"))

    # --- figures ---
    plt = setup_matplotlib()
    fig_tps(plt, stats)
    fig_latency(plt, stats)
    fig_cost(plt, cost_rows[:len(CONFIGS)])
    for env, _, model in CONFIGS:
        first = sorted(glob.glob(os.path.join(ROOT, "results", env, "burnin-*")))
        mains = [d for d in first if os.path.exists(os.path.join(d, "burnin-azure-metrics.json"))
                 and "PHASE=main" in open(os.path.join(d, "meta.env")).read()]
        if mains:
            fig_burnin(plt, env, model, mains[0])

    # --- console summary ---
    print(f"prices: {os.path.relpath(args.prices, ROOT)} (retrieved {snapshot['retrieved_at']})")
    for r in cost_rows:
        s = stats[r["env"]]["tps"]
        print(f"{SHORT[r['env']]:16} k={s['k']} TPS {s['mean']:8.1f} ±{(s['half'] or 0):6.1f} | "
              f"${r['usd_per_hour']:.4f}/h ${r['usd_per_month']:7.2f}/month | "
              f"{r['tx_per_usd_m']:.2f} M tx/$ [{r['tx_per_usd_m_lo']:.2f}; {r['tx_per_usd_m_hi']:.2f}] | "
              f"${r['usd_per_m_tx']:.3f}/M tx")
    print(f"written: {os.path.relpath(OUT, ROOT)}/results.csv, cost.csv, tables/, figures/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

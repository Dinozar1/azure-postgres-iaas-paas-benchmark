#!/usr/bin/env python3
"""Draw the order of measurement sessions for the main campaign.

Usage:
  draw-campaign.py --seed SEED [--rounds 4] [--first-round 1]
                   [--envs ENV ...] [--out campaign/round-order.csv]

A round is one session of each configuration. When the number of rounds
equals the number of configurations (the campaign's initial 4 rounds), the
order is a random Latin square: every configuration takes every position in
the round exactly once, so when a round runs back to back the time of day
rotates across configurations instead of one always running at night. It is
drawn by permuting the rows, columns and symbols of a cyclic square with the
given seed. Any other number of rounds (the extra sessions the stopping rule
grants, for a subset of configurations given with --envs) gets an
independent random order per round.

The draw is appended to the output file together with its seed, time and
method, so the order is documented before any session runs; rounds already in
the file are never redrawn.
"""
import argparse
import csv
import datetime
import os
import random
import sys

CONFIGURATIONS = ["iaas-standard-ssd", "iaas-premium-ssd", "paas-burstable", "paas-general-purpose"]


def latin_square(envs, rng):
    n = len(envs)
    rows = rng.sample(range(n), n)
    cols = rng.sample(range(n), n)
    symbols = rng.sample(envs, n)
    return [[symbols[(rows[r] + cols[c]) % n] for c in range(n)] for r in range(n)]


def existing_rounds(path):
    if not os.path.exists(path):
        return set()
    with open(path, newline="") as f:
        return {int(r["round"]) for r in csv.DictReader(line for line in f if not line.startswith("#"))}


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--rounds", type=int, default=4)
    ap.add_argument("--first-round", type=int, default=1)
    ap.add_argument("--envs", nargs="+", default=CONFIGURATIONS)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "campaign", "round-order.csv"))
    args = ap.parse_args(argv)

    unknown = [e for e in args.envs if e not in CONFIGURATIONS]
    if unknown:
        ap.error(f"not in the main matrix: {unknown}")
    wanted = set(range(args.first_round, args.first_round + args.rounds))
    clash = wanted & existing_rounds(args.out)
    if clash:
        ap.error(f"rounds {sorted(clash)} are already drawn in {args.out}; draws are never redone")

    rng = random.Random(args.seed)
    if args.rounds == len(args.envs):
        order, method = latin_square(args.envs, rng), "random Latin square (rows, columns, symbols of a cyclic square permuted)"
    else:
        order, method = [rng.sample(args.envs, len(args.envs)) for _ in range(args.rounds)], "independent random order per round"

    new_file = not os.path.exists(args.out)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "a", newline="") as f:
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        f.write(f"# rounds {args.first_round}-{args.first_round + args.rounds - 1}: seed={args.seed} drawn_at={now} method={method}\n")
        w = csv.writer(f)
        if new_file:
            w.writerow(["round", "position", "environment", "seed"])
        for i, row in enumerate(order):
            for pos, env in enumerate(row, 1):
                w.writerow([args.first_round + i, pos, env, args.seed])
    for i, row in enumerate(order):
        print(f"round {args.first_round + i}: " + "  ->  ".join(row))
    print(f"written: {os.path.normpath(args.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

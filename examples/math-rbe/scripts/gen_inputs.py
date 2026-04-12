#!/usr/bin/env python3
"""gen_inputs.py — generate randomised CSV input datasets for load testing.

Each invocation with a different --seed produces a distinct set of (a, b, op)
rows whose Bazel action keys will be cache misses on the RBE cluster.
This is how load_test.sh forces fresh remote execution rather than AC hits.

Usage:
    python3 scripts/gen_inputs.py --rows 200 --seed 42 --out data/inputs_custom.csv

The generated file is NOT a Bazel target — it is written to a temp path and
fed directly to the runner binary for ad-hoc load tests outside Bazel.
For in-Bazel use, commit the CSV and add a filegroup() in data/BUILD.bazel.
"""

import argparse
import csv
import random
import sys


def generate(rows: int, seed: int) -> list[dict]:
    rng = random.Random(seed)
    records = []
    for _ in range(rows):
        # Wide range of a values to produce varied outputs (reduces AC hit rate
        # across runs since action inputs differ even for same op).
        a = round(rng.uniform(1.0, 10000.0), 4)
        # Avoid b == 0 for div rows so we don't flood error_count in stats.
        # Occasionally allow small b to stress the near-zero path.
        b = round(rng.uniform(0.01, 500.0), 4)
        op = rng.choice(["mul", "div"])
        records.append({"a": a, "b": b, "op": op})
    return records


def main():
    p = argparse.ArgumentParser(description="Generate randomised math-rbe input CSV")
    p.add_argument("--rows",  type=int, default=50,  help="number of data rows")
    p.add_argument("--seed",  type=int, default=0,   help="random seed for reproducibility")
    p.add_argument("--out",   type=str, default="-", help="output path (default: stdout)")
    args = p.parse_args()

    records = generate(args.rows, args.seed)

    if args.out == "-":
        writer = csv.DictWriter(sys.stdout, fieldnames=["a", "b", "op"])
    else:
        f = open(args.out, "w", newline="")
        writer = csv.DictWriter(f, fieldnames=["a", "b", "op"])

    writer.writeheader()
    writer.writerows(records)

    if args.out != "-":
        f.close()
        print(f"wrote {args.rows} rows (seed={args.seed}) → {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()

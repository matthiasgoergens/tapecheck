#!/usr/bin/env python3
"""Paired analysis for probe_calculator's retained per-seed observations."""

import csv
import random
import statistics
import sys


def percentile(values: list[float], probability: float) -> float:
    ordered = sorted(values)
    return ordered[round(probability * (len(ordered) - 1))]


def bootstrap_mean_ci(values: list[float], *, samples: int = 50_000) -> tuple[float, float]:
    rng = random.Random(20_260_812)
    n = len(values)
    means = [statistics.fmean(values[rng.randrange(n)] for _ in range(n)) for _ in range(samples)]
    return percentile(means, 0.025), percentile(means, 0.975)


def main(path: str) -> None:
    by_unit: dict[int, dict[str, dict[str, int]]] = {}
    with open(path, newline="", encoding="utf-8") as source:
        for row in csv.DictReader(source, delimiter="\t"):
            unit = int(row.pop("unit"))
            arm = row.pop("arm")
            by_unit.setdefault(unit, {})[arm] = {key: int(value) for key, value in row.items()}

    pairs = [by_unit[unit] for unit in sorted(by_unit)]
    if any(set(pair) != {"stock", "structural"} for pair in pairs):
        raise SystemExit("every experimental unit must contain both arms")

    print(f"paired units: {len(pairs)}")
    for field in ("attempts", "nodes", "rendered_bytes"):
        differences = [pair["structural"][field] - pair["stock"][field] for pair in pairs]
        mean = statistics.fmean(differences)
        lo, hi = bootstrap_mean_ci(differences)
        print(f"structural - stock {field}: mean {mean:.2f}, bootstrap 95% CI [{lo:.2f}, {hi:.2f}]")

    stock_only = sum(
        pair["stock"]["exact"] == 1 and pair["structural"]["exact"] == 0
        for pair in pairs
    )
    structural_only = sum(
        pair["stock"]["exact"] == 0 and pair["structural"]["exact"] == 1
        for pair in pairs
    )
    print(f"discordant exact pairs: stock only {stock_only}, structural only {structural_only}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} OBSERVATIONS.tsv")
    main(sys.argv[1])

#!/usr/bin/env python3
"""Validate and analyse the predeclared inactive-seam upper-bound study."""

from __future__ import annotations

import csv
import json
import math
import random
import statistics
import sys
from pathlib import Path

BLOCKS = 60
BOOTSTRAP_SAMPLES = 100_000
BOOTSTRAP_SEED = 20_260_822
DRAWS = ("bool", "int_0_1000", "float_0_1")
CONTRASTS = ("isolated", "module", "active")
METRICS = ("seconds", "instructions", "cycles", "branches", "branch_misses")
UPPER_QUANTILE = 1.0 - 0.05 / len(DRAWS)
LOWER_QUANTILE = 0.05 / len(DRAWS)
NONINFERIORITY_LIMIT = 1.05
POSITIVE_CONTROL_LIMIT = 1.02


def percentile(values: list[float], probability: float) -> float:
    ordered = sorted(values)
    position = probability * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1.0 - weight) + ordered[upper] * weight


def interval(values: list[float], coverage: float) -> list[float]:
    tail = (1.0 - coverage) / 2.0
    return [percentile(values, tail), percentile(values, 1.0 - tail)]


def read_and_validate(path: Path) -> dict[tuple[str, str], list[dict[str, str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle, delimiter="\t"))
    expected = BLOCKS * len(DRAWS) * len(CONTRASTS)
    if len(rows) != expected:
        raise ValueError(f"expected {expected} paired rows, found {len(rows)}")

    grouped = {(contrast, draw): [] for contrast in CONTRASTS for draw in DRAWS}
    seen: set[tuple[int, str, str]] = set()
    for row in rows:
        block = int(row["block"])
        contrast = row["contrast"]
        draw = row["draw"]
        key = block, contrast, draw
        if key in seen:
            raise ValueError(f"duplicate pair {key}")
        seen.add(key)
        if block not in range(BLOCKS) or contrast not in CONTRASTS or draw not in DRAWS:
            raise ValueError(f"unexpected pair {key}")
        expected_order = (
            "numerator_first"
            if (block + CONTRASTS.index(contrast) + DRAWS.index(draw)) % 2 == 0
            else "denominator_first"
        )
        if row["order"] != expected_order:
            raise ValueError(f"wrong order for {key}: {row['order']}")
        if row["numerator_accumulator"] != row["denominator_accumulator"]:
            raise ValueError(f"accumulator mismatch for {key}")
        for metric in METRICS:
            numerator = float(row[f"numerator_{metric}"])
            denominator = float(row[f"denominator_{metric}"])
            if numerator <= 0.0 or denominator <= 0.0:
                raise ValueError(f"non-positive {metric} for {key}")
        grouped[(contrast, draw)].append(row)

    for key, values in grouped.items():
        if len(values) != BLOCKS:
            raise ValueError(f"expected {BLOCKS} rows for {key}, found {len(values)}")
        orders = [row["order"] for row in values]
        if orders.count("numerator_first") != BLOCKS // 2:
            raise ValueError(f"unbalanced order for {key}")
    return grouped


def analyse_metric(rows: list[dict[str, str]], metric: str, rng: random.Random) -> dict[str, object]:
    logs = [
        math.log(float(row[f"numerator_{metric}"]) / float(row[f"denominator_{metric}"]))
        for row in rows
    ]
    boot = [statistics.fmean(rng.choices(logs, k=len(logs))) for _ in range(BOOTSTRAP_SAMPLES)]
    ci90 = [math.exp(value) for value in interval(boot, 0.90)]
    ci95 = [math.exp(value) for value in interval(boot, 0.95)]
    return {
        "geometric_mean_ratio": math.exp(statistics.fmean(logs)),
        "ci90_ratio": ci90,
        "ci95_ratio": ci95,
        "familywise_95_lower_ratio": math.exp(percentile(boot, LOWER_QUANTILE)),
        "familywise_95_upper_ratio": math.exp(percentile(boot, UPPER_QUANTILE)),
        "median_ratio": math.exp(statistics.median(logs)),
        "paired_log_ratios": logs,
    }


def analyse(grouped: dict[tuple[str, str], list[dict[str, str]]]) -> dict[str, object]:
    rng = random.Random(BOOTSTRAP_SEED)
    results: dict[str, object] = {
        "blocks": BLOCKS,
        "bootstrap_samples": BOOTSTRAP_SAMPLES,
        "bootstrap_seed": BOOTSTRAP_SEED,
        "familywise_confidence": 0.95,
        "noninferiority_limit": NONINFERIORITY_LIMIT,
        "positive_control_limit": POSITIVE_CONTROL_LIMIT,
        "contrasts": {},
    }
    contrasts = results["contrasts"]
    assert isinstance(contrasts, dict)
    for contrast in CONTRASTS:
        contrast_result: dict[str, object] = {}
        contrasts[contrast] = contrast_result
        for draw in DRAWS:
            draw_result = {
                metric: analyse_metric(grouped[(contrast, draw)], metric, rng)
                for metric in METRICS
            }
            seconds = draw_result["seconds"]
            assert isinstance(seconds, dict)
            draw_result["time_noninferior_within_five_percent"] = (
                seconds["familywise_95_upper_ratio"] <= NONINFERIORITY_LIMIT
            )
            draw_result["positive_control_detected"] = (
                seconds["familywise_95_lower_ratio"] >= POSITIVE_CONTROL_LIMIT
            )
            contrast_result[draw] = draw_result
    return results


def render(result: dict[str, object]) -> str:
    contrasts = result["contrasts"]
    assert isinstance(contrasts, dict)
    lines = [
        "# Inactive interception seam upper-bound result",
        "",
        "Ratios are numerator/denominator. The primary isolated contrast is",
        "`seam/direct`; its decision uses the familywise-95% one-sided upper bound",
        "and a predeclared 1.05 non-inferiority limit.",
        "",
    ]
    labels = {
        "isolated": "Primary: production inactive check / same compiled direct body",
        "module": "Secondary: complete seam module / stripped no-hook module",
        "active": "Positive control: delegating active observer / inactive seam",
    }
    for contrast in CONTRASTS:
        lines.extend([
            f"## {labels[contrast]}",
            "",
            "| Draw | Time ratio | 95% CI | Familywise lower | Familywise upper | Instructions ratio |",
            "|---|---:|---:|---:|---:|---:|",
        ])
        contrast_result = contrasts[contrast]
        assert isinstance(contrast_result, dict)
        for draw in DRAWS:
            draw_result = contrast_result[draw]
            assert isinstance(draw_result, dict)
            seconds = draw_result["seconds"]
            instructions = draw_result["instructions"]
            assert isinstance(seconds, dict) and isinstance(instructions, dict)
            ci95 = seconds["ci95_ratio"]
            assert isinstance(ci95, list)
            lines.append(
                f"| `{draw}` | {seconds['geometric_mean_ratio']:.5f} | "
                f"{ci95[0]:.5f}–{ci95[1]:.5f} | "
                f"{seconds['familywise_95_lower_ratio']:.5f} | "
                f"{seconds['familywise_95_upper_ratio']:.5f} | "
                f"{instructions['geometric_mean_ratio']:.5f} |"
            )
        lines.append("")

    isolated = contrasts["isolated"]
    active = contrasts["active"]
    assert isinstance(isolated, dict) and isinstance(active, dict)
    primary_pass = all(
        bool(isolated[draw]["time_noninferior_within_five_percent"])  # type: ignore[index]
        for draw in DRAWS
    )
    positive_pass = all(
        bool(active[draw]["positive_control_detected"])  # type: ignore[index]
        for draw in DRAWS
    )
    lines.extend([
        f"Primary all-draw decision: **{'pass' if primary_pass else 'fail'}**.",
        f"Positive-control sensitivity decision: **{'pass' if positive_pass else 'fail'}**.",
        "",
        "All raw paired observations are retained in `pairs.tsv`; per-arm observations",
        "are in `arms.tsv`, full statistics in `analysis.json`, and host/toolchain",
        "metadata in `environment.txt`. No observation was excluded.",
        "",
    ])
    return "\n".join(lines)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: analyse_bound.py RESULT_DIRECTORY")
    result_dir = Path(sys.argv[1])
    grouped = read_and_validate(result_dir / "pairs.tsv")
    result = analyse(grouped)
    (result_dir / "analysis.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (result_dir / "RESULT.md").write_text(render(result), encoding="utf-8")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Validate and analyse the predeclared unused-seam benchmark."""

from __future__ import annotations

import argparse
import csv
import json
import math
import random
import statistics
from pathlib import Path

EXPECTED_PROCESSES = 12
EXPECTED_BLOCKS = 10
BOOTSTRAP_SAMPLES = 50_000
BOOTSTRAP_SEED = 20_260_820
EQUIVALENCE_MARGIN = (0.98, 1.02)
DRAW_KINDS = ("bool", "int_0_1000", "float_0_1")


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


def read_rows(result_dir: Path) -> list[dict[str, str]]:
    files = sorted(result_dir.glob("process-*.tsv"))
    if len(files) != EXPECTED_PROCESSES:
        raise ValueError(
            f"expected {EXPECTED_PROCESSES} process files, found {len(files)}"
        )
    rows: list[dict[str, str]] = []
    for path in files:
        with path.open(newline="", encoding="utf-8") as handle:
            data_lines = (line for line in handle if not line.startswith("#"))
            rows.extend(csv.DictReader(data_lines, delimiter="\t"))
    return rows


def validate(rows: list[dict[str, str]]) -> dict[str, dict[int, list[float]]]:
    grouped = {
        draw: {process_id: [] for process_id in range(EXPECTED_PROCESSES)}
        for draw in DRAW_KINDS
    }
    seen: set[tuple[int, int, str]] = set()
    draw_counts: set[int] = set()
    orders = {
        draw: {
            process_id: {"seam_first": 0, "nohook_first": 0}
            for process_id in range(EXPECTED_PROCESSES)
        }
        for draw in DRAW_KINDS
    }

    for row in rows:
        process_id = int(row["process_id"])
        block = int(row["block"])
        draw = row["draw"]
        order = row["order"]
        if process_id not in range(EXPECTED_PROCESSES):
            raise ValueError(f"unexpected process id {process_id}")
        if block not in range(EXPECTED_BLOCKS):
            raise ValueError(f"unexpected block {block}")
        if draw not in DRAW_KINDS:
            raise ValueError(f"unexpected draw kind {draw}")
        key = process_id, block, draw
        if key in seen:
            raise ValueError(f"duplicate observation {key}")
        seen.add(key)
        draw_counts.add(int(row["draws"]))
        nohook_seconds = float(row["nohook_seconds"])
        seam_seconds = float(row["seam_seconds"])
        if nohook_seconds <= 0.0 or seam_seconds <= 0.0:
            raise ValueError(f"non-positive timing in {key}")
        if int(row["nohook_acc"]) != int(row["seam_acc"]):
            raise ValueError(f"accumulator mismatch in {key}")
        if order not in orders[draw][process_id]:
            raise ValueError(f"unexpected order {order}")
        orders[draw][process_id][order] += 1
        grouped[draw][process_id].append(math.log(seam_seconds / nohook_seconds))

    if len(draw_counts) != 1:
        raise ValueError(f"inconsistent draw counts: {sorted(draw_counts)}")
    for draw in DRAW_KINDS:
        for process_id in range(EXPECTED_PROCESSES):
            logs = grouped[draw][process_id]
            if len(logs) != EXPECTED_BLOCKS:
                raise ValueError(
                    f"expected {EXPECTED_BLOCKS} {draw} blocks for process "
                    f"{process_id}, found {len(logs)}"
                )
            if orders[draw][process_id] != {"seam_first": 5, "nohook_first": 5}:
                raise ValueError(
                    f"unbalanced order for {draw} process {process_id}: "
                    f"{orders[draw][process_id]}"
                )
    return grouped


def bootstrap(
    process_effects: list[float], combine, rng: random.Random
) -> list[float]:
    count = len(process_effects)
    return [
        combine(rng.choices(process_effects, k=count))
        for _ in range(BOOTSTRAP_SAMPLES)
    ]


def analyse(grouped: dict[str, dict[int, list[float]]]) -> dict[str, object]:
    rng = random.Random(BOOTSTRAP_SEED)
    result: dict[str, object] = {
        "bootstrap_samples": BOOTSTRAP_SAMPLES,
        "bootstrap_seed": BOOTSTRAP_SEED,
        "equivalence_margin_ratio": list(EQUIVALENCE_MARGIN),
        "draws": {},
    }
    draw_results = result["draws"]
    assert isinstance(draw_results, dict)
    for draw in DRAW_KINDS:
        process_means = [
            statistics.fmean(grouped[draw][process_id])
            for process_id in range(EXPECTED_PROCESSES)
        ]
        mean_bootstrap = bootstrap(process_means, statistics.fmean, rng)
        process_medians = [
            statistics.median(grouped[draw][process_id])
            for process_id in range(EXPECTED_PROCESSES)
        ]
        median_bootstrap = bootstrap(process_medians, statistics.median, rng)
        ci90 = [math.exp(value) for value in interval(mean_bootstrap, 0.90)]
        ci95 = [math.exp(value) for value in interval(mean_bootstrap, 0.95)]
        median_ci95 = [
            math.exp(value) for value in interval(median_bootstrap, 0.95)
        ]
        draw_results[draw] = {
            "geometric_mean_ratio": math.exp(statistics.fmean(process_means)),
            "ci90_ratio": ci90,
            "ci95_ratio": ci95,
            "equivalent_within_two_percent": (
                ci90[0] >= EQUIVALENCE_MARGIN[0]
                and ci90[1] <= EQUIVALENCE_MARGIN[1]
            ),
            "process_mean_log_ratios": process_means,
            "sensitivity_median_ratio": math.exp(
                statistics.median(process_medians)
            ),
            "sensitivity_median_ci95_ratio": median_ci95,
        }
    return result


def render_markdown(
    result: dict[str, object], *, title: str, numerator: str, denominator: str
) -> str:
    draw_results = result["draws"]
    assert isinstance(draw_results, dict)
    lines = [
        f"# {title}",
        "",
        f"Ratios are {numerator}/{denominator}; values above 1 indicate a slower "
        f"{numerator} build.",
        "The equivalence decision uses the predeclared 90% interval and ±2% margin.",
        "",
        "| Draw | Geometric ratio | 90% CI | 95% CI | Within ±2%? |",
        "|---|---:|---:|---:|:---:|",
    ]
    for draw in DRAW_KINDS:
        value = draw_results[draw]
        assert isinstance(value, dict)
        ci90 = value["ci90_ratio"]
        ci95 = value["ci95_ratio"]
        assert isinstance(ci90, list) and isinstance(ci95, list)
        equivalent = "yes" if value["equivalent_within_two_percent"] else "no"
        lines.append(
            f"| `{draw}` | {value['geometric_mean_ratio']:.5f} | "
            f"[{ci90[0]:.5f}, {ci90[1]:.5f}] | "
            f"[{ci95[0]:.5f}, {ci95[1]:.5f}] | {equivalent} |"
        )
    lines.extend(
        [
            "",
            "The process-level median sensitivity estimates and intervals are in",
            "`analysis.json`. This narrow result does not measure an active interceptor",
            "or end-to-end property-test performance.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("result_directory", type=Path)
    parser.add_argument("--title", default="Unused interception seam result")
    parser.add_argument("--numerator-label", default="seam")
    parser.add_argument("--denominator-label", default="no-hook")
    args = parser.parse_args()
    rows = read_rows(args.result_directory)
    grouped = validate(rows)
    result = analyse(grouped)
    analysis_path = args.result_directory / "analysis.json"
    analysis_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (args.result_directory / "RESULT.md").write_text(
        render_markdown(
            result,
            title=args.title,
            numerator=args.numerator_label,
            denominator=args.denominator_label,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()

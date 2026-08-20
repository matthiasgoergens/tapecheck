# Current matched shrink comparison

Generated from the per-seed evidence pinned by Tapecheck's `EVIDENCE.md`.
Every cell contains 100 deterministic seeds. Final Wave 1 and current
ordinary Wave 2 are byte-for-byte identical on these observations, so they
share one column. A dash means the structural-list arm does not apply.

## Quality

| Property | Base stock | Tape ordinary | Tape structural | Hypothesis 6.164.0 |
|---|---:|---:|---:|---:|
| Integer threshold | 0/100 exact (100 found) | 100/100 exact (100 found) | — | 100/100 exact (100 found) |
| Pair sum | 0/100 exact (100 found) | 100/100 exact (100 found) | — | 100/100 exact (100 found) |
| List length | 0/100 exact (100 found) | 100/100 exact (100 found) | 100/100 exact (100 found) | 100/100 exact (100 found) |
| List sum | 0/100 exact (100 found) | 100/100 exact (100 found) | 100/100 exact (100 found) | 100/100 exact (100 found) |
| Filtered even integer | 0/100 exact (100 found) | 100/100 exact (100 found) | — | 100/100 exact (100 found) |
| Length-prefixed bind | 0/100 exact (100 found) | 100/100 exact (100 found) | — | 100/100 exact (100 found) |
| Zig-zag | 11/100 exact (83 found) | 83/100 exact (83 found) | — | 67/100 exact (67 found) |
| Head equals length | 46/100 exact (98 found) | 47/100 exact (98 found) | 99/100 exact (99 found) | 53/100 exact (89 found) |

## Mean property calls

| Property | Base stock | Tape ordinary | Tape structural | Hypothesis 6.164.0 |
|---|---:|---:|---:|---:|
| Integer threshold | 0.00 | 35.89 | — | 55.74 |
| Pair sum | 0.00 | 20.23 | — | 35.42 |
| List length | 6.35 | 151.21 | 41.55 | 27.94 |
| List sum | 4.70 | 94.52 | 25.58 | 28.55 |
| Filtered even integer | 0.00 | 80.94 | — | 27.51 |
| Length-prefixed bind | 0.00 | 51.69 | — | 47.93 |
| Zig-zag | 0.00 | 35.93 | — | 150.04 |
| Head equals length | 3.53 | 134.01 | 13.13 | 107.94 |

Every mean is over seeds where that arm found a failure. Base and Tape counts
cover shrinking only. Hypothesis counts generation and shrinking, so the
Hypothesis cost column is not directly comparable and is shown only to
establish scale. Base's zeroes on scalar and bind rows mean an
atomic or absent shrinker, not a zero-cost successful reduction.

The OCaml stock and ordinary tape arms share each original failing value.
Structural lists and Hypothesis intentionally generate their own originals,
so comparisons involving those columns are complete-arm results rather than
pure shrinker effects. This selected matrix is not evidence of blanket
quality or performance parity.

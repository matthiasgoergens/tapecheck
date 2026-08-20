# Interleaved continuation spans with a running budget

This is the missing fourth cell from `PROBE-LIST-DESIGN.md`. The source and
raw output are tracked in the same commit as this note.

## Predeclared question and analysis

The prediction was committed in `PROBE-LIST-DESIGN.md` at `2b44069`, before
this arm was implemented or run. The estimands are aggregate generated string
length, retry attempts per successful capped-tree draw, exact-minimum frequency,
shrink attempts per failure, and generated list length. The experimental unit
is a deterministic seed. All arms use the same seed sets and are run in one
process; comparisons are therefore paired by seed, although this exploratory
probe reports only aggregate counts and means.

The primary success criteria were: maximum aggregate string length at most 50;
retry attempts per successful draw materially below the prior 0.791; and
minimality and attempt counts close to the unbudgeted `continuation+span` arm.
The existing deterministic stopping rules were retained: 20,000 seeds for
lengths, 100 for flat shrink cases, 50 for recursive shrink quality, 10,000 for
generation tails, and 1,000 for taped recursive costs. Runtime state and the
element generator are nuisance factors; the paired seeds, fixed sizes, single
process, stock controls, and unchanged arms control them as far as this probe
allows. The ten-string case is a positive control for reachability of the
maximum list length.

## Provenance and reproduction

- Date: 2026-08-20 (Asia/Singapore)
- Baseline revision: `2b44069381faf75c40ece8e16883280103427a11`
- OCaml switch: `5.3.0`
- Dune: `3.24.0`
- Build: `opam exec --switch=5.3.0 -- nice -n 10 ionice -c 2 -n 7 dune build probe_list_design/probe_list_design.exe`
- Run: `opam exec --switch=5.3.0 -- nice -n 10 ionice -c 2 -n 7 dune exec probe_list_design/probe_list_design.exe`
- Exit status: 0
- Raw stdout: `2026-08-20-interleaved-budget.txt`
- Determinism check: a second complete run was byte-for-byte identical (`cmp`
  exit status 0).

## Result

The full separability prediction is refuted.

The budget restores the size contract: aggregate string length has mean 22.14
and maximum 50, versus mean 479.49 and maximum 2,179 without the budget. It
also eliminates the observed leaf-cap cost: zero retry attempts in 20,000
successful generation-tail draws and zero in the separate 1,000 taped draws,
versus 15,820 and 720 respectively without the budget.

Shrink minima remain strong on the three reachable integer-list cases:
100/100 for `length >= 3`, 99/100 for `sum >= 100`, and 100/100 for
`hd = length`. The corresponding unbudgeted-span results were 100/100,
100/100, and 99/99. Efficiency does not remain close: attempts per failure
rise from 41 to 208, 25 to 33, and 13 to 56. Recursive trees still reach the
exact 20-node minimum in 50/50 seeds, but attempts rise from 154 to 851.

Most importantly, allocating element sizes before knowing the final length
changes the length distribution. At size 10, mean raw length falls from 3.591
for stock and 3.599 for unbudgeted spans to 1.956. The ten-string positive
control finds no failure in 100 seeds × 200 cases: early elements commonly
consume budget needed for later structural charges. Therefore this particular
crossing cell is bounded and shrinks to good minima, but it is not a shippable
replacement for Base's list generator and does not by itself supersede PR #29.

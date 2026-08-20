# Interleaved continuation spans with a payload-only budget

This follow-up tests the alternative size contract predeclared in
`PROBE-LIST-DESIGN.md`. The implementation and raw output are tracked with this
note; the prediction predates both.

## Predeclared question and analysis

The prediction was committed at `7f75a35d04ae2ab81f309b76f9702290372b6042`.
The estimands, paired deterministic seed sets, nuisance factors, stopping rules,
controls, and thresholds are recorded there. In brief, the arm had to preserve
the stock length distribution, keep aggregate strings at or below 50, keep
leaf-cap retries below 0.1 per draw, remain close to the unbudgeted span arm's
flat and recursive shrink quality and cost, and restore reachability of the
ten-string positive control. Any failed screen made this a retained negative
result.

## Provenance and reproduction

- Date: 2026-08-20 (Asia/Singapore)
- Predeclaration revision: `7f75a35d04ae2ab81f309b76f9702290372b6042`
- OCaml: 5.3.0
- Dune: 3.24.0
- Build: `opam exec --switch=5.3.0 -- dune build probe_list_design/probe_list_design.exe`
- Run: `opam exec --switch=5.3.0 -- dune exec probe_list_design/probe_list_design.exe`
- Exit status: 0
- Raw stdout: `2026-08-20-payload-budget.txt`
- Determinism check: two complete runs made before retaining the output were
  byte-for-byte identical; the retained third run was also identical.

## Result

The arm is rejected by its predeclared screens.

It removes the strong length bias of the structurally charged online budget:
raw mean length is 3.642, against 3.591 for stock and 1.956 for that earlier
arm. The absolute difference from stock is 0.051, narrowly outside the fixed
0.05 screen. Taped mean length is 3.582. The ten-string failure is reachable
in 100/100 seeds, and capped recursive generation records zero retries in both
20,000 generation-tail draws and 1,000 separately taped draws.

The predeclared aggregate-string bound fails: maximum total length is 78 at
size 50. This is not an accounting bug in the new arm. Base's `G.string`
chooses a length up to its element size plus one. The earlier structural charge
paid that extra unit once per element; removing it makes the realised aggregate
bound `size + length`, at most `2 * size`, rather than `size`. The observed 78
is inside the proposed relaxed structural-plus-payload contract but outside the
fixed production screen.

Shrink quality also fails decisively. `length >= 3` and `sum >= 100` retain
100/100 exact minima, but `hd = length` falls from the unbudgeted span arm's
99 exact minima to 75. Attempts per failure are 219, 37, and 96, versus 41,
25, and 13; the first and third exceed the two-times screen. Recursive trees
still reach the exact 20-node minimum in 50/50 seeds, but take 605 attempts per
failure versus the allowed 308. The ten-string case is found in every seed but,
like every control arm in this probe, does not reach ten empty strings.

The result sharpens the trade-off rather than resolving it. Decoupling list
nodes from payload budget restores reachability and avoids leaf-cap retries,
but weakens Base's realised size bound and gives back much of the structural
arm's shrink-cost and `hd = length` advantage. This arm is not a production
candidate and does not supersede PR #29.

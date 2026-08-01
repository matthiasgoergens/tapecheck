# The Shrinking Challenge

[jlink/shrinking-challenge](https://github.com/jlink/shrinking-challenge)
is the cross-language benchmark for shrinkers, with published reports
from ten libraries — Hypothesis, jqwik, PropEr, FsCheck, fast-check,
CsCheck, Americium, elm-test, rapid, Exhaust. There is no OCaml entry.

Implemented in `challenge/`. Their report format is the right one and is
kept: for each challenge, what the shrinker **normalises** to (does it
reach the same canonical answer regardless of starting point?) and what
that costs in **evaluations**. Quality and cost together.

## Protocol

100 runs per challenge. "Evaluations" counts test executions from the
first failing example onward — the cost of shrinking, not of finding.
Their harness reports the same quantity, so the columns are comparable.

Two things had to be matched deliberately, and the second was got wrong
first:

- Their published Hypothesis numbers are from **5.23.11, in 2020**.
  Quoting them against a 2026 tapecheck would be unfair in both
  directions, so current Hypothesis (6.164.0) is re-measured under the
  same harness. It has improved a lot: `reverse` went from mean 45.95
  evaluations to 17.65.
- Their harness runs with `max_examples = 10**6`. An earlier tapecheck
  run used `count = 500` and reported 11/100 found on
  `difference_must_not_be_one` — which says nothing about the shrinker
  and everything about a generation budget two thousand times too
  small. At matched budget it is 100/100. **The corrected numbers are
  the ones below.**

## Results

`tapecheck` is stock. `+patch` applies
`proposals/base_quickcheck-non_uniform.patch`, a distribution-preserving
change to `base_quickcheck` described in
`proposals/BASE-QUICKCHECK-ENCODING.md`.

| challenge | Hypothesis 6.164.0 | tapecheck | tapecheck +patch |
|---|---|---|---|
| reverse | **100/100**, 17.6 | 0/100, 294.0 | 50/100, 278.8 |
| distinct | **100/100**, 48.5 | 0/100, 418.5 | 12/100, 417.7 |
| large_union_list | **100/100**, 208.2 | 0/100, 1317.7 | 0/100, 1256.7 |
| calculator | **100/100**, 191.2 | 3/100, 880.5 | 4/100, — |
| bound5 | **100/100**, 157.4 | 17/100, 267.7 | 17/100, — |
| lengthlist | **100/100**, 87.7 | 64/100, 298.8 | 64/100, 298.8 |
| difference_must_not_be_zero | 100/100, 40.6 | 100/100, 93.9 | 100/100, 93.9 |
| difference_must_not_be_small | 100/100, 726.8 | 100/100, **92.8** | 100/100, **92.8** |
| difference_must_not_be_one | 100/100, 883.4 | 100/100, **94.5** | 100/100, **94.5** |

Cells are `normalised / mean evaluations`.

## Reading it

**Hypothesis normalises everything, 100/100, on all nine.** That is the
headline and it is not close. It is also better than their own 2020
report, so it is current work rather than legacy.

**tapecheck reaches 100/100 on three of nine.**

**Where we lose, one cause dominates and it is not the shrinker.**
reverse, distinct and large_union_list are the three built on
`base_quickcheck`'s unbounded `Generator.int`, which reaches `max_int`
through a two-choice tape and `1` through a four-choice tape. Shortlex
is length-first, so `max_int` ranks below `1` and the shrinker
converges, correctly by its own order, onto answers full of
`4611686018427387903`. Diagnosis and a distribution-preserving fix in
`proposals/BASE-QUICKCHECK-ENCODING.md`: `reverse` 0/100 → 50/100,
`distinct` 0/100 → 12/100, and cost *down* on all three.

**calculator and bound5 are the span gap, in a third and fourth dress.**
calculator's misses are long inert chains — `('+', ('+', ('+', 0, 0),
0), 0)` — wrapped around a small failing subterm the shrinker cannot
promote to the root. That is `pass_to_descendant`, the same thing
`test_poison/` prices at 10/34 (see `SPANS-THE-ROOT-CAUSE.md`). The
`max_int` issue shows here too but only as flavour: with the patch the
divisors become `('/', 0, -1)` instead of `('/', 0, max_int)`, and the
inert chains remain, so the score does not move.

**lengthlist is ours, and the obvious fix was tried and reverted.** Its
misses all stop with `converged = false` and the global budget
untouched, so it is a cap rather than a capability gap: the per-pass
failure cutoff is a flat 20, which is a very different fraction of a
200-choice tape than of a 20-choice one. Making it proportional
(`max 20 (len/3)`) takes this to 100/100 at *half* the cost and leaves
the nine other guarded properties untouched — and breaks `test_poison`,
whose size-2 base tree then stops shrinking at 50 leaves instead of 2.
The floor grants long-tape patience to unproductive passes too, paid for
out of the global budget, which is what the flat cutoff exists to
prevent. Measured at divisors 3, 4, 6, 8: at 3 it binds and poison
breaks; at 4 and above it never binds and nothing changes. No window.

The real fix is *earned* patience — a pass's allowance scaled by its own
success rate, in the spirit of `fixate_shrink_passes` — which is a
design change rather than a constant, and is not done. lengthlist is
recorded as a frontier in `test_regression/regression_guard.ml` so it
cannot silently get worse, and an improvement is flagged too.

**Where we win, we win on what the suite calls hardest.** The
`difference` family requires holding a dependency between two
separately-drawn integers, and the spec singles out
`difference_must_not_be_one` as "the most difficult one to shrink
because shrinking parameters individually will never lead to a smaller
and falsifying sample". We match Hypothesis 100/100 at **9.3x lower
cost** and near-deterministically: 94..95 evaluations against their
54..1056. That is `lower_together` (their `lower_integers_together`,
ported after `test_zig_zagging.py` caught us) doing what it was ported
to do.

## Three measurement errors worth recording

The first two would have gone unnoticed, and both distorted the
comparison in our favour.

**Budget mismatch, flattering us.** First run gave tapecheck
`count = 500` against their `max_examples = 10**6`, and the `difference`
rows read as 11/100 *found*. That measured a generation budget two
thousand times too small.

**A repr artefact, flattering us again.** Hypothesis's bound5 answer
prints as `([], [], [], [np.int16(-1)], [np.int16(-32768)])`, so a
string compare against the challenge's stated answer scored it 0/100
while the values were identical. It is 100/100. The harness now
normalises numpy scalar reprs.

**And one that cost half an hour.** `calculator`'s generator is
`recursive_union` with two recursive branches out of three, so node
count grows exponentially in `size`: mean 37 nodes at size 8, 1357 at
size 20 (`diag2/probe_calcgen.ml`). Run at the suite's default size 30
it produced nothing for thirty minutes. It runs at size 8, which is what
the suite now uses. Worth noting that Hypothesis's `st.deferred` has no
size knob and is bounded by their buffer limit instead — the more robust
arrangement for a recursive generator.

## Not yet implemented

`binheap`, `coupling`, `deletion` and `nestedlists` have no Hypothesis
implementation in the upstream repo and are unstarted here.

Contributing an OCaml entry upstream is an outward-facing action and is
not done.

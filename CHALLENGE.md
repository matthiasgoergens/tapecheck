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

1000 runs per challenge. "Evaluations" counts test executions from the
first failing example onward — the cost of shrinking, not of finding.
Their harness reports the same quantity, so the columns are comparable.

Two things had to be matched deliberately, and the second was got wrong
first:

- Their published Hypothesis numbers are from **5.23.11, in 2020**.
  Quoting them against a 2026 tapecheck would be unfair in both
  directions, so current Hypothesis (6.164.0) is re-measured from ported
  challenge definitions with the same evaluation-count convention. It has
  improved a lot: `reverse` went from mean 45.95 evaluations to 17.65.
- Their harness runs with `max_examples = 10**6`. An earlier tapecheck
  run used `count = 500` and reported 11/100 found on
  `difference_must_not_be_one` — which says nothing about the shrinker
  and everything about a generation budget two thousand times too
  small. At matched budget it is 100/100. **The corrected numbers are
  the ones below.**
- The current tapecheck harness uses that one-million generation budget by
  default, but overrides `calculator` to 20,000 and `bound5` to 200,000.
  Those lower caps make failures harder to find and therefore do not flatter
  tapecheck's normalisation score, but they are an asymmetry and are now stated
  explicitly. `calculator` also runs at size 8 because the corresponding
  `recursive_union` grows exponentially at the default size 30.
- Tapecheck shrinking is capped at 20,000 total replay proposals and 500
  accepted shrinks. Selected passes start with a 20-failure allowance;
  `lower_and_delete` can earn additional patience after successes. Hypothesis
  uses its own accepted-shrink and stall limits rather than those exact
  controls. The total tape budget was non-binding in these measurements (the
  largest observed run used 7,881 proposals), but the protocols are not
  identical and the table should be read as comparative evidence, not a
  controlled timing benchmark.

The OCaml harness defaults to 100 runs for quick local use. Reproduce the
reported sample size with:

```
TAPECHECK_RUNS=1000 dune exec challenge/challenge.exe
```

The `+patch` column requires applying
`proposals/base_quickcheck-non_uniform.patch` first. The Hypothesis column
comes from the separate `hypothesis-baseline` branch, not this executable.

## Results

`tapecheck` is stock. `+patch` applies
`proposals/base_quickcheck-non_uniform.patch`, a distribution-preserving
change to `base_quickcheck` described in
`proposals/BASE-QUICKCHECK-ENCODING.md`.

| challenge | Hypothesis 6.164.0 | tapecheck | tapecheck +patch |
|---|---|---|---|
| reverse | **1000/1000**, 17.7 | 0/1000, 293.8 | 452/1000, 284.4 |
| distinct | **1000/1000**, 49.1 | 0/1000, 436.7 | 116/1000, 437.1 |
| large_union_list | **1000/1000**, 211.3 | 0/1000, 1344.8 | 0/1000, 1314.7 |
| calculator | **1000/1000**, 103.3 | 16/1000, 912.0 | 14/1000, 910.1 |
| bound5 | **1000/1000**, 154.8 | 0/1000, 285.0 | 0/1000, 297.0 |
| lengthlist | **1000/1000**, 87.9 | **1000/1000**, 82.8 | **1000/1000**, 82.8 |
| difference_must_not_be_zero | 1000/1000, 40.5 | 1000/1000, **85.5** | 1000/1000, **85.5** |
| difference_must_not_be_small | 1000/1000, 721.6 | 1000/1000, **97.5** | 1000/1000, **97.5** |
| difference_must_not_be_one | 1000/1000, 885.2 | 1000/1000, **98.6** | 1000/1000, **98.6** |

Cells are `normalised / mean evaluations`, **1000 runs each**. 95%
Wilson intervals are in the raw output; the ones that matter are quoted
inline below.

Both tapecheck columns re-measured 2026-08-08 at `3aa0a47`; raw output
in `../tapecheck-notes/challenge-1000-20260808.txt` and
`challenge-1000-patched-20260808.txt`.

**`difference_must_not_be_zero` re-measured 2026-08-14** at 98.0 to
85.5 mean evaluations, when `minimize_duplicated_choices` was enabled
by default (raw:
`../tapecheck-notes/challenge-1000-duplate-20260814.txt`). That pass
lowers a whole group of equal-valued choices at once, which is exactly
this challenge's shape; quality is unchanged at 1000/1000, and every
other row moved by under 1% FROM THAT PASS, measured against the
2026-08-13 reorder baseline in
`../tapecheck-notes/challenge-1000-reorder-20260813.txt`. Read against
the column previously printed here, bound5 also moved — 158/1000 to
0/1000 exact and 276.8 to 285.0 — but that is `reorder_spans`, not this
pass, and is explained below. The `+patch` column was
re-measured on 2026-08-19 against the same master
(`../tapecheck-notes/challenge-1000-patched-20260819.txt`) and moves
the same way, to 85.5. The pass must run after the deletion and lowering passes — placed before them it costs the
poisoned-containers guard 21/48 to 17/48, measured, see
`WAVE2-REORDER-AND-DUPLICATES.md`.

**lengthlist now normalises, which is the row that moved.** It was
716/1000 at 261.0 when this table was first written and is 1000/1000 at
82.8 now: three times the quality at a third of the cost, from the
computed repair rather than from any budget increase. That makes
tapecheck 4/9 rather than 3/9. The discussion further down still
describes it as an open frontier in places; that text is kept as the
history of how it was reached, not as a current description.

The four challenges ported later are measured too, and are the honest
remainder of the suite rather than a separate category:

| challenge | tapecheck | tapecheck +patch |
|---|---|---|
| deletion | 17/1000, 2158.2 | 296/1000, 2248.5 |
| nestedlists | 18/1000, 645.5 | 18/1000, 645.5 |
| coupling | 18/1000, 2335.8 | 18/1000, 2335.8 |
| binheap | 93/1000, 1175.4 | 93/1000, 1175.4 |

`<= optimal size` is worth reading alongside `exact` for these: bound5
reaches 999/1000 at-or-below optimal size (1000/1000 in the `+patch`
arm) while scoring 0 exact in both,
because the challenge scores one exact permutation of five symmetric
slots. Same for binheap, 299/1000 at-or-below against 93 exact.

**bound5's exact score fell to 0 in both arms when `reorder_spans`
landed, and that is not a regression in reduction.** Before the pass,
the answer set was 22 distinct arrangements of which 158/1000 happened
to be the challenge's permutation; the pass canonicalises them to 2,
with 999/1000 on a single arrangement (the `+patch` arm reaches 1
distinct answer) — `([], [], [], [-32768], [-1])`
rather than the expected `([], [], [], [-1], [-32768])`. Normalisation
is what the suite asks for and the pass delivers it; it settles on the
wrong representative because shortlex ranks the two-entry `-32768`
recording ahead of `-1`'s three entries, which is the `non_uniform`
encoding pathology showing through the sort key. A value-aware key was
tried and rejected by measurement — see
`WAVE2-REORDER-AND-DUPLICATES.md`.

## Reading it

**Hypothesis normalises everything, 1000/1000, on all nine.** That is the
headline and it is not close. It is also better than their own 2020
report, so it is current work rather than legacy.

**tapecheck reaches full normalisation on four of nine** — `lengthlist` and the
three `difference` variants.

**bound5's score is not a shrink-quality result at all, in either
column.** Measured directly over 1000 runs (`diag2/probe_bound5.ml`):
**all 1000 reduce to exactly two elements, and 998 of them to the right
content** — two singleton lists holding `-1` and `-32768`, three
empties. What varies is *which of the five slots* the singletons land
in, and the challenge scores one exact permutation. So the score
measures positional canonicalisation, not reduction — which is why
`reorder_spans` moved it to 0 while improving the thing the suite
actually asks for. (The 158/1000 quoted below is the pre-`reorder_spans`
figure; the reasoning it supports is unchanged.)

That reframes the `+patch` column too. It gains 50 points on `reverse`
and 12 on `distinct`, shaves cost on `large_union_list` and
`calculator`, and moves `bound5` from 17 to 7 — but that last is the
patch preferring a *different permutation* of an equally minimal answer
(`([], [], [], [-32768], [-1])` instead of `([], [], [], [-1],
[-32768])`), not a worse counterexample.

The five slots are symmetric, so canonicalising them means moving
content between positions — which is `reorder_spans`, and needs spans.
bound5's residue is the span gap wearing yet another hat, alongside
`calculator` and the poisoned trees.

**A cleverer encoding does not rescue it, and I tried.** Ordering the
`non_uniform` branches by distance from the shrink target rather than
positionally — general branch first when the range straddles zero, so
that `-1` sorts ahead of `-32768` instead of behind it — is the
principled fix for the value ordering, and it works at the value level.
It makes normalisation *worse*: 87 distinct answers against 17, because
removing the strong `lo`-first preference leaves many slot
configurations tied. Cost did fall 30% (268 to 188). Not adopted; the
simpler patch is the proposal.

**Where we lose, one cause dominates and it is not the shrinker.**
reverse, distinct and large_union_list are the three built on
`base_quickcheck`'s unbounded `Generator.int`, which reaches `max_int`
through a two-choice tape and `1` through a four-choice tape. Shortlex
is length-first, so `max_int` ranks below `1` and the shrinker
converges, correctly by its own order, onto answers full of
`4611686018427387903`. Diagnosis and a distribution-preserving fix in
`proposals/BASE-QUICKCHECK-ENCODING.md`. The 100-run pilot measured
`reverse` 0/100 → 50/100 and `distinct` 0/100 → 12/100 with cost down
on all three; the 1000-run table above gives the current figures,
`reverse` 452/1000 and `distinct` 116/1000.

**calculator and bound5 are the span gap, in a third and fourth dress.**
calculator's misses are long inert chains — `('+', ('+', ('+', 0, 0),
0), 0)` — wrapped around a small failing subterm the shrinker cannot
promote to the root. That is `pass_to_descendant`, the same thing
`test_poison/` priced at 10/34 when this was written (see
`SPANS-THE-ROOT-CAUSE.md`). The
`max_int` issue shows here too but only as flavour: with the patch the
divisors become `('/', 0, -1)` instead of `('/', 0, max_int)`, and the
inert chains remain, so the score does not move.

**Update, 2026-08-12: `pass_to_descendant` landed** on
`wave2/span-deletion` behind an opt-in `descendable` capability. The
poisoned trees go 12/34 to 34/34 with the capability, matching
Hypothesis, and the test asserts both arms. It does not rescue
calculator's exact normalisation: on the paired diag2 sample the
descendant pass removes every inert recursive wrapper (replay attempts
501.3 to 438.6, nodes 5.6 to 5.0) but exact canonical renderings move
1/100 to 0/100 — too sparse to distinguish from seed variation, and the
five-node residue can still hold the wrong operator or literal
arrangement. That residue belongs to choice minimisation, sibling
reordering (`reorder_spans`) and duplicate-span handling, not to
another descendant pass. The table above is therefore unchanged by the
pass and remains the honest current score.

**lengthlist: earned patience helps a little.** A shrink pass's failure
allowance is now the flat base plus one extra per success it has already
banked in this shrink, so patience is earned rather than granted. At
n=1000 that moves it 683/1000 to 716/1000 and drops cost 283 to 261,
with nothing else on the suite changing and `test_poison` intact.

Report that carefully: the quality intervals overlap ([65.4, 71.1]
against [68.7, 74.3]), so the +3.3 points is suggestive, not
established. The cost drop is firmer. Both runs use identical seeds, so
comparing independent-sample intervals is conservative here — a paired
test would have more power and has not been run.

**The obvious fix, by contrast, was tried and reverted.** Its
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
success rate, in the spirit of `fixate_shrink_passes`.

**Superseded, 2026-08-08.** Earned patience landed, and then the
computed repair took lengthlist to 1000/1000 at 82.8 without raising
any bound and without costing `test_poison`, which went 10/34 to 12/34
rather than down. Everything above this paragraph is the record of a
problem that is now solved; it is kept because the *reasoning* about
why the flat cutoff and the proportional floor both fail is still
correct and still worth not rediscovering.

lengthlist is guarded in `test_regression/regression_guard.ml` so it
cannot silently get worse — and, since 2026-08-08, so that an
improvement cannot silently pass either. The claim that "an improvement
is flagged too" was made here long before anything implemented it, and
the gap is exactly how the 716 → 1000 move went unnoticed in this file:
`check` applied a one-sided floor, so a property that had reached
100/100 kept printing `ok` under a name asserting it had not. There is
now a `high_minimal` bound that fails on improvement, kill-tested by
lowering it and confirming the failure.

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

## binheap, and one more measurement error

`binheap` is the eleventh upstream case, a GENERATION challenge rather
than a shrinking one, and is implemented in `challenge/challenge.ml`.
Measured at n=100 a side, using the same integer seed labels (the different
engines do not thereby receive paired generated inputs):

| | exact | 95% CI | <= optimal size | distinct | mean evaluations |
|---|---|---|---|---|---|
| Hypothesis 6.164.0 | 65/100 | 55.3-73.6 | 78/100 | 4 | 169 |
| tapecheck | 6/100 | 2.8-12.5 | 30/100 | 54 | 1195 |

An earlier version of this comparison read 27/100 exact [19.3-36.4] for
tapecheck. The generator used 3:1 empty:node, jqwik parity, against the
Hypothesis baseline's 1:1 (`st.none() | node`), and the heavier leaf
weight puts small heaps much denser in the input distribution. Matched
at 1:1 the gap is wider than reported, on cost as well as quality. Same
flattering-mismatch class as the budget bug above, one layer down.

## Not yet implemented

`coupling`, `deletion` and `nestedlists` are implemented in
`challenge/` but have no Hypothesis implementation in the upstream
repo.

Contributing an OCaml entry upstream is an outward-facing action and is
not done.

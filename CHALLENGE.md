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
| lengthlist | **100/100**, 87.7 | 64/100, 298.8 | 64/100, 298.8 |
| difference_must_not_be_zero | 100/100, 40.6 | 100/100, 93.9 | 100/100, 93.9 |
| difference_must_not_be_small | 100/100, 726.8 | 100/100, **92.8** | 100/100, **92.8** |
| difference_must_not_be_one | 100/100, 883.4 | 100/100, **94.5** | 100/100, **94.5** |

Cells are `normalised / mean evaluations`.

## Reading it

**Hypothesis normalises everything, 100/100, on all seven.** That is the
headline and it is not close. It is also a stronger result than their
own 2020 report claims for them, so it is current work rather than
legacy.

**Where we lose, we lose to one cause and it is not the shrinker.** The
three challenges we fail — reverse, distinct, large_union_list — are the
three built on `st.lists(st.integers())`, i.e. on `base_quickcheck`'s
unbounded `Generator.int`. That generator reaches `max_int` through a
two-choice tape and `1` through a four-choice tape, so shortlex ranks
`max_int` below `1` and the shrinker converges, correctly by its own
order, onto answers full of `4611686018427387903`. Full diagnosis and a
distribution-preserving fix in
`proposals/BASE-QUICKCHECK-ENCODING.md`; it takes `reverse` from 0/100
to 50/100 and *reduces* cost. The remaining gap there is a milder second
instance of the same thing (`-1` is cheaper to encode than `1`).

`lengthlist` is a different and genuine weakness: 64/100, and the misses
are lists that never got down to one element. That one is ours.

**Where we win, we win on the challenges the suite says are hardest.**
The `difference` family requires holding a dependency between two
separately-drawn integers, and the spec singles out
`difference_must_not_be_one` as "the most difficult one to shrink
because shrinking parameters individually will never lead to a smaller
and falsifying sample". We match Hypothesis's answer 100/100 at **9.3x
lower cost** — and near-deterministically: our evaluation range is
94..95 against their 54..1056. That is `lower_together` (their
`lower_integers_together`, ported after `test_zig_zagging.py` caught us
falling into the trap) doing exactly what it was ported to do, plus the
correlated-value mutation making the case findable at all.

So the honest summary is: on normalisation we are behind, mostly for one
fixable reason in the host library; on joint-dependency shrinking we are
substantially ahead, on the cases the benchmark's own author flagged as
hardest.

## Not yet implemented

`calculator` (recursive expression generator plus `assume`) and `bound5`
(five filtered `int16` lists) are measured for Hypothesis in
`../tapecheck-hypothesis-baseline/challenge/` but not yet on our side.
`binheap`, `coupling`, `deletion`, `nestedlists` have no Hypothesis
implementation in the upstream repo and are unstarted here.

Contributing an OCaml entry upstream is an outward-facing action and is
not done.

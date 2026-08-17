# Wave 2 design: capability-gated `reorder_spans` and `minimize_duplicated_choices`

Written 2026-08-13, before implementation. Revised the same day after
the adversarial design reviews (codex break-it, DeepSeek alternatives);
the revisions section at the end records what each review changed. The
next two span-dependent passes from `WAVE2-PASS-TO-DESCENDANT.md`,
measured on the known `bound5`, `large_union_list`, calculator and
poison-tree trade-offs.

## Prior art (verified against the vendored Hypothesis sources)

`reorder_spans` (shrinker.py): choose a span, choose a label among its
children, collect the **children sharing that label**, and run
`Ordering.shrink` over their indices with `sort_key` — shortlex over
the child's choice sequence — so the canonical arrangement is the
sorted one. The motivating case is two `st.text()` draws with
`x != y`, which otherwise fail as either `("", "0")` or `("0", "")`.

`minimize_duplicated_choices` (shrinker.py): find choices whose values
have been duplicated in multiple places, drop the trivial ones, and
call `minimize_nodes` on the whole set at once — lower all duplicates
simultaneously. Motivating case: `ls = draw(lists(integers()))`,
`y = draw(integers())`, `assert y not in ls`, shrunk to `y = 3`,
`ls = [3]` — lowering either 3 alone makes the test pass; lowering both
together is a valid shrink.

Both passes exist as tapecheck approximations already: `sort_siblings`
is a span-free signature guess, hard-disabled after re-measurement at
n=1000 (`+patch` only: distinct 116→649, reverse 452→487, binheap
93→110 — but lengthlist regressed); `redistribute_pairs` is the
pairwise, sum-preserving cousin of duplicate minimisation. This design
retires neither: the new passes are opt-ins, and the approximations
stay for the stock columns.

## Design: `reorder_spans`

1. **Seam.** New capability `reorderable` on the span record, widened
   through every gate the reviews enumerated: `Tape.span` and
   `open_span` fields, `on_span_start`/`on_span_stop` arguments and the
   retention fast-paths, start/stop balance equality, exceptional
   clearing, retention conditions, span comparison, the shim's
   independent start filter, both `sr_real` callback record
   declarations plus `with_span` and its interface, the vendor patch,
   the bonsai consumer snapshot (sync script checked), and the test
   interceptors. A capability-only start whose stop is dropped must
   still balance — the shim filter and the Tape gates widen together.
   Unchanged generators pass `false` everywhere and retain nothing.

2. **Direct-child representation.** Spans are flat intervals today; a
   permutation pass needs direct children. The open-span stack knows
   the depth at every stop event, so `Tape.span` gains `depth : int`
   recorded at close. Direct children of a parent span are retained
   spans with `depth = parent.depth + 1` that are properly contained
   in it. No parent-pointer metadata, no inference.

3. **Grouping, per Hypothesis.** Choose a label among the *children*
   of a `reorderable` parent (not the parent's own label), collect the
   direct children sharing that label, all also `reorderable`. At
   least two, or the pass moves on.

4. **Proposal and acceptance.** One proposal per group: the children's
   slices rearranged into shortlex order, the parent's own gaps kept in
   place — a single parent-interval reconstruction, not per-pair
   swaps. Accept only a still-failing, whole-image-smaller replay.
   After every accepted proposal, abandon all cached groups, arrays
   and indices and rebuild from the fresh replay; the engine already
   replaces `s_best_spans` on acceptance. Candidates are enumerated
   deterministically (children by position, labels in ascending label
   order, never by hash order) before any failure cutoff applies.
   Proposals already present in the global seen table are skipped,
   since replay can accept an output different from the submitted
   proposal.

5. **Scope restriction.** Main stream only, and only groups whose
   slices contain no `Marker` choices: `Generator.fn` splits a keyed
   stream at a marker, and reordering slices across a marker would
   cross-wire the payload. Root-stream only is inherited from
   `pass_to_descendant` for the same ancestry reason.

6. **Sort key — an honest caveat.** Shortlex is the faithful port, but
   tapecheck's `non_uniform` encoding contaminates it: `-32768` has a
   two-entry recording and sorts ahead of `-1`'s three entries, while
   `bound5`'s expected permutation wants `-1` first. So the sorted
   arrangement is canonical but can be the *wrong* canonical
   permutation for `bound5`; the same pathology the +patch column
   already shows. The first measurement decides: if `bound5` exact does
   not move toward the expected permutation, the follow-up is a
   value-aware key (distance from the shrink target, the
   `sort_siblings` target-aware variant), which is a separate measured
   change, not a silent one.

7. **Fixpoint honesty.** The sorted-arrangement proposal alone does not
   reach a sorted fixpoint in general (`[B,C,A]` where failure needs
   the first child to be `B`: `[A,B,C]` passes, `[B,A,C]` is smaller
   and failing, and is never proposed). The pass may settle unsorted;
   `Ordering.shrink`'s permutation search, or a bounded
   adjacent-transposition fallback, is the measured next step rather
   than a claim.

## Design: `minimize_duplicated_choices`

1. **No new capability.** Hypothesis groups over the whole buffer, and
   the DeepSeek alternatives review made the case for not widening the
   seam again: the pass is instead restricted to integer and float
   choices — the kinds with a defined shrink order — with equal
   `(kind, value, lo, hi)`. Equal bounds matter: replay clamps a
   proposed value independently per position, so equal values in
   different ranges can replay apart and destroy the group.

2. **Mechanism.** For each group of at least two non-trivial values,
   bisect the shared value toward its kind's shrink direction for all
   members simultaneously — one proposal per bisection step. Downward
   means toward zero for integers; the float and sign conventions come
   from the existing `minimize_choices` machinery. Acceptance is the
   usual replay gate; stale-geometry and determinism rules are shared
   with `reorder_spans`. All-members bisection can miss subset moves
   (a length choice of the same value is excluded by the bounds/kind
   gate, but genuine subset cases remain); a subset-splitting fallback
   is the noted refinement, matching Hypothesis's own all-members
   scope.

## Measurement protocol (predeclared)

Same-seed columns, not paired-interval claims: the harness drops seed
identity, so per-seed discordance and paired cost intervals are not
computable without harness work. Reported as parallel same-seed runs
at n=1000, plus the 200-seed pilot stage:

- `bound5` — reorder target. Predeclared risk: the sort-key caveat
  above may leave exact normalisation unchanged even while the
  at-or-below-optimal-size column improves.
- `large_union_list` — expected `[[0, 1, -1, 2, -2]]` is an ordering;
  reorder should reduce the distinct-answer count.
- calculator — the residue after `pass_to_descendant`; measure whether
  either pass moves the 16/1000 exact without accepting longer chains.
- `deletion` — the duplicate positive control (expected `([0, 0], 0)`,
  the case `minimize_duplicated_choices` exists for).
- poison-tree guard — the stock arm's 12/34 floor becomes two-sided
  (exactly 12/34, the existing `high_minimal` pattern from
  `CHALLENGE.md`), and the structural 34/34 must hold unchanged.
- Negative control: same-seed pre-shrink tape images identical across
  arms, asserted once per run.

Staged: existing guards first (full forced suite, regression guard,
poison), then 200-seed targeted runs, then the full 1000-seed
columns. Any guard improvement is kill-tested both directions per
`CHALLENGE.md`'s existing discipline.

## Measured: `reorder_spans` on the challenge suite

Measured 2026-08-13 at n=1000, same seeds as the stock column
(`challenge-1000-20260808.txt`). Only `bound5` carries reorderable
spans so far; raw output in
`tapecheck-notes/challenge-1000-reorder-20260813.txt`.

| | stock | +reorder spans |
|---|---|---|
| bound5 distinct answers | 22 | **2** (999 × one arrangement) |
| bound5 at-or-below optimal size | 998/1000 | **999/1000** |
| bound5 exact | 158/1000 | 0/1000 |
| bound5 mean evaluations | 276.8 | 284.8 |

Every other challenge row is identical to the stock column to two
decimals — the pass is inert where nothing opts in, which is the point
of the capability gate.

The canonical arrangement is `([], [], [], [-32768], [-1])`: shortlex
ranks the two-entry `-32768` recording ahead of `-1`'s three entries,
the predeclared sort-key caveat, and the same order the `+patch` column
already prefers. Normalisation consistency is delivered; the
challenge's expected permutation needs the value-aware key, which is
the next measured step. The poisoned-trees guard stays 12/34 and 34/34,
with the stock floor now two-sided and kill-tested.

## The poisoned-containers trap: measured, diagnosed, fixed

**The trap was pass ORDERING.** An earlier note in this file blamed the
pass for zeroing duplicated *structural* draws (matrix and list
dimensions). That was wrong, and the measurement that refuted it is
recorded here so the mistake is not repeated: tracing the accepted
proposals on the discriminating seed (Matrices size 10, p=1/100,
seed 1284235381287210546) shows all three accepted moves preserving the
image length exactly — `size 80 -> 80` — at positions spread through
the payload (`4,18,22,24,28,32,36`). Seven duplicated `1`s cannot be
matrix dimensions; these are element draws. A structural gate built on
the dimension hypothesis (skip any group whose target proposal changes
the replayed image length) was implemented, measured completely inert,
and removed.

The pass ran EARLY in the sweep, before `lower_and_delete`.
Pre-zeroing duplicated payload values removes the raw material that
pass needs for its combined lower-then-delete move — the length-repair
move that length-prefixed data depends on. Moving
`minimize_duplicated_choices` to run after the deletion and lowering
passes resolves it:

| poisoned containers | exact minima |
|---|---:|
| pass off (baseline) | 21/48 |
| pass on, early placement | 17/48 |
| pass on, late placement | **21/48**, per-case identical to baseline |

## What the pass earns in its late slot

Same-seed challenge columns at n=1000 (raw:
`tapecheck-notes/challenge-1000-duplate-20260814.txt` against the
pass-off column `challenge-1000-reorder-20260813.txt`):

| challenge | pass off | pass on, late |
|---|---:|---:|
| difference_must_not_be_zero | 98.0 | **85.5** |
| large_union_list | 1338.8 | 1344.8 |
| nestedlists | 640.9 | 645.5 |
| bound5 | 284.8 | 285.0 |
| binheap | 1175.6 | 1175.4 |

Cells are mean shrink evaluations. **Every quality column is identical**
— normalisation, exact counts and at-or-below-optimal-size all
unchanged on all thirteen challenges. The one material move is a 12.8%
cost reduction on `difference_must_not_be_zero`, whose failing inputs
are literally a duplicated pair, which is the case the pass exists for.
The increases elsewhere are under 1%.

The full forced suite is green in BOTH arms, including the
poisoned-containers and poisoned-trees guards, which it was not with
the early placement.

**The default is deliberately not flipped.** Following the
`sort_siblings` precedent in `engine/tape_engine.ml` — a shipping
default is not a call to make silently — the pass stays behind
`TAPECHECK_MINIMIZE_DUPLICATES=1` with the evidence above. The
recommendation is to enable it: no measured quality regression, one
real cost win, guards green.

## Remaining gap: the pass has no live regression test

A test that pins the pass needs a property where deletion cannot
reproduce the failure. The obvious candidate — three integers that must
be equal — does not work: the deletion passes erase the value-carrying
choices and the fixed-seed replay (`replay_fresh_seed`) resamples them
with the boundary-biased generator, reproducing the equal values, so
the deletion is accepted and the equality "solved" without any
duplicate move. The reported minimal then lives partly in fresh draws:
self-consistent and reproducible, but the pass never sees the group.
`difference_must_not_be_zero` is the workload where the pass demonstrably
pays, so a guard row there (mean evaluations, two-sided) is the cheapest
real pin and is the next step.

## Note on the measurement protocol

The protocol's promised in-harness negative control (same-seed
pre-shrink image assertion) was not implemented; the byte-identical
non-bound5 columns across the 1000-run artefacts are the de facto
control instead.

## Revisions after the design reviews

- **Grouping rule** (codex): children share a chosen *child* label,
  not the parent's label. Direct children via recorded span depth.
- **Split-stream hazard** (codex): main-stream, marker-free slices
  only; `Generator.fn` keyed payloads must not be cross-wired.
- **Sort-key caveat** (codex): shortlex + `non_uniform` predicts the
  wrong `bound5` permutation; predeclared measurement decides whether
  the value-aware key is needed.
- **Fixpoint and stale-geometry discipline** (codex): rebuild after
  every acceptance, deterministic enumeration, seen-table skips,
  withdraw the convergence claim.
- **`duplicable` dropped** (DeepSeek): whole-tape grouping gated by
  equal `(kind, value, lo, hi)` instead of a third capability bit.
- **The trap, and the correction** (measured 2026-08-14): the early
  placement's poisoned-containers regression was pass ORDERING, not
  structural-draw zeroing as an earlier revision of this file claimed.
  See the trap section above for the refuting measurement.
- **Measurement protocol** (both): `deletion` positive control added;
  same-seed columns replace paired-interval claims; poison floor
  becomes two-sided; negative control added; staged pilot first.
- **Retention checklist** (codex): the full gate list is in the seam
  section above and is checked mechanically by the widened
  start/stop-balance tests and the sync scripts.

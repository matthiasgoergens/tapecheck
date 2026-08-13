# Wave 2 design: capability-gated `reorder_spans` and `minimize_duplicated_choices`

Written 2026-08-13, before implementation. The next two span-dependent
passes from `WAVE2-PASS-TO-DESCENDANT.md`, restricted to explicit
generator capabilities as decided there, measured on the known
`bound5`, `large_union_list`, calculator and poison-tree trade-offs on
paired seeds.

## Prior art (verified against the vendored Hypothesis sources)

`reorder_spans` (shrinker.py): choose a span, choose a label among its
children, collect the children sharing that label, and run
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
retires neither: the real passes are gated opt-ins, and the
approximations stay for the stock columns.

## Design: `reorder_spans`

1. **Seam.** New capability `reorderable` on the span record
   (`tape/tape.ml`: field, `on_span_start`/`on_span_stop` arguments,
   the retention fast-path, and the span comparison), mirrored through
   the `Intercept` callbacks in `vendor/base_quickcheck`,
   `vendor/splittable_random`, the patches, and the bonsai consumer
   snapshot (the sync script checks these stay in step). Unchanged
   generators pass `false` everywhere and retain nothing, exactly as
   with the other three capabilities.

2. **Pass.** For each span marked `reorderable` (root stream only,
   same rationale and boundary rules as `pass_to_descendant`: properly
   contained children, shared endpoints allowed), collect its child
   spans that are also `reorderable` and share the parent's label. If
   at least two, propose the shortlex-sorted arrangement of their
   slices as a single proposal — one attempt per group, not per
   permutation pair, matching `sort_siblings`' cost discipline and the
   per-pass failure cutoff. Accept only a still-failing,
   shortlex-smaller replay. Re-sort with every accepted proposal, as
   the other passes do, so the fixpoint converges to the sorted
   arrangement.

3. **Explicit non-goal.** `Ordering.shrink`'s permutation search (it
   explores reorderings beyond the sorted one, with its own search
   discipline). The sorted arrangement is the normalisation target;
   the permutation search is a later refinement if measurement shows
   the sorted proposal alone is insufficient.

4. **Generator exposure.** First, mark the challenge generators'
   spans via the raw seam in `challenge/` and the paired probes.
   A public opt-in combinator follows only if the measurements justify
   it, following the `WAVE2-PRODUCTION-GENERATORS.md` pattern.

## Design: `minimize_duplicated_choices`

1. **Seam.** Second new capability `duplicable`, same plumbing as
   `reorderable`. A `duplicable` span declares that the values inside
   it may legitimately duplicate and that duplicates should be
   minimised together.

2. **Pass.** Within each `duplicable` span (root stream only), group
   positions by equal `(kind, value)`, skipping values that are already
   trivial for their kind. For each group of at least two, bisect the
   shared value downward for all members simultaneously — one proposal
   per bisection step for the whole group — accepting a still-failing
   replay. This is `redistribute_pairs` generalised from two nodes to
   N same-value nodes, using the same machinery and cutoffs.

3. **Interaction with `reorder_spans`.** The two passes compose: after
   reordering, duplicated values sit at adjacent positions, but the
   duplicate pass does not depend on adjacency (it groups by value over
   the span, not by position runs).

## Measurement protocol (predeclared)

Paired 1000 seeds, stock vs each capability vs both, on:

- `bound5` — the canonical reorder test: 998/1000 at-or-below optimal
  size but 158/1000 exact because the five symmetric slots are not
  canonically ordered. Prediction: `reorderable` on the slot spans
  moves exact toward the Hypothesis 1000/1000 without changing size
  or cost class.
- `large_union_list` — expected `[[0, 1, -1, 2, -2]]` is an ordering;
  reordering should normalise more of the 726 distinct answers.
- calculator — the residue after `pass_to_descendant` is choice
  minimisation and sibling ordering; measure whether either pass moves
  the 16/1000 exact without accepting longer chains.
- poison-tree guard — both the 12/34 unchanged floor and the 34/34
  structural result must hold unchanged.

Also the full forced suite and the regression guard must stay green;
any guard improvement is kill-tested both directions per
`CHALLENGE.md`'s existing discipline. Costs are mean shrink
evaluations per the challenge convention.

## Known risks to weigh in review

- The old approximation hurt lengthlist via wasted attempts; the real
  pass can waste attempts too (labels are generator-declared, but
  reordering groups that cannot accept any swap still cost the cutoff).
- Sorting by shortlex inside a span changes the tape layout under the
  span's own boundary — the parent's recorded slice positions must be
  rebuilt from the replay, which the engine already does on every
  accepted proposal (`s_best_spans`).
- Two more capabilities widen the intercept record again; upstream
  `splittable_random#2` has still not merged, and each widening makes
  the eventual upstream proposal heavier.

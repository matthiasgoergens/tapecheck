# Hypothesis baseline for tapecheck's shrink table

tapecheck is a port of Hypothesis's Conjecture engine, so Hypothesis is
the reference. `shrink_table_hypothesis.py` runs the six properties from
tapecheck's `demo/shrink_table.ml` against Hypothesis itself, same
generators, predicates, minimality criteria and 100 seeds.

Run: `uv run python shrink_table_hypothesis.py`

## Result

Quality is matched: **both reach 100/100 fully minimal on all six.**
The port preserved what it was meant to preserve.

Cost is not:

| property | tapecheck (shrink only) | Hypothesis (gen+shrink) |
|---|---|---|
| int uniform in [0, 1_000_000] | 38 | 55 |
| pair in [0,1000]^2 | 22 | 35 |
| **int list, length >= 3** | **641** | **27** |
| **int list, sum >= 100** | **456** | **28** |
| filtered even ints | 90 | 27 |
| bind, list_with_length | 59 | 47 |

The two list properties cost ~23x and ~16x more in tapecheck, and the
table understates it: Hypothesis's column includes the generation phase
that tapecheck's `attempts` column excludes.

Scalars and the bind case are fine — comparable or better. **The problem
is specific to list-shaped data.**

## Why this matters for the roadmap

`head_to_head/VERIFICATION.md` measured a 5.5x shrink-cost overhead
against qcheck-stm and treated it as the cost of the tape's better
minimality. That framing is too generous. Against the reference
implementation of the very same algorithm the gap is 20x, and only on
lists, which is the signature of a defect rather than a design tradeoff.

Order of work, revised:

1. **Find where the 641 calls go** on `int list, fail iff length >= 3`.
   Instrument per-pass and per-proposal: how many attempts are exact
   duplicates, how many are spent in the greedy `while !again` repeat
   loop, how many per pass. A 20x gap on one data shape is unlikely to
   need a new framework to fix.
2. Only then consider Hypothesis's pass reordering and exhaustion
   tracking (`ChoiceTree`), per `SHRINK-BUDGET-DESIGN.md`.

Doing (2) first would be building infrastructure to schedule work that
may not need doing at all.

## Where the calls actually go (measured)

`diag/where_do_calls_go.ml` in the budget worktree attributes attempts
per pass:

```
int list, fail iff length >= 3 (100 failing runs)
  lower_and_delete        613 avg attempts     <-- 96% of the total
  minimize_choices         13
  redistribute_pairs       13
  delete_streams            0
  duplicates               65 avg (10% of proposals were exact repeats)

int list, fail iff sum >= 100
  lower_and_delete        431 avg attempts     <-- 95% of the total
  minimize_choices         20
  duplicates               92 avg (20% repeats)

int uniform (control, already cheap)
  minimize_choices         37
  lower_and_delete          0                  <-- costs nothing here
```

**One pass is the whole gap.** Not scheduling, not duplicates.

Cause, at the greedy repeat loop inside `lower_and_delete`:

```ocaml
let step =
  if Int64.(value > clamp64 0L ~lo ~hi) then Int64.( - ) value 1L
  else Int64.( + ) value 1L
```

It lowers by **one** per attempt, so driving a list element from 100 to
0 costs 100 attempts, per element. `minimize_choices` already binary
searches (`while high - low > 1`), which is why it costs 13-37 and why
the scalar control is cheap.

### Consequences for the roadmap

- **Fix: give `lower_and_delete` the galloping/binary search that
  `minimize_choices` already has.** This is the `find_integer` item
  already queued in `coordinate-work/open-items.md` and described there
  as "~15 lines, faster shrinking for free". It now has a measured 20x
  justification rather than being speculative.
- **Pass reordering is NOT the fix and would have been wasted work.**
  The expensive pass is also the productive one, so no scheduler can
  help. Had `SHRINK-BUDGET-DESIGN.md`'s ordering been followed, the
  infrastructure would have been built before discovering it schedules
  work that should not exist.
- Exhaustion tracking is worth at most the 10-20% duplicate rate, i.e.
  second-order next to a 20x.

This is the "try the naive thing first" rule paying: measuring where the
calls went cost one afternoon's instrumentation and redirected the work
away from a framework nobody needed.

## All six, 500 trials: TWO distinct causes, not one

Re-run at 500 seeds (numbers stable vs the 100-seed run: 612 vs 613,
427 vs 431, so this is signal).

| property | dominant pass | cost | Hypothesis |
|---|---|---|---|
| int list, length >= 3 | `lower_and_delete` | 612 | 27 |
| int list, sum >= 100 | `lower_and_delete` | 427 | 28 |
| filtered even | **`minimize_choices`** | **95** | 27 |
| bind | `lower_and_delete` 40 + `minimize_choices` 18 | 59 | 47 |
| pair | `minimize_choices` | 19 | 35 |
| int uniform (control) | `minimize_choices` | 37 | 55 |

### Cause 1 — lists and bind: linear integer descent

`lower_and_delete` steps a value by ONE per attempt. Driving an element
from 100 to 0 costs 100 attempts, per element. `minimize_choices`
already binary searches, which is why the scalar rows are cheap.

Fix: the `find_integer` galloping search already queued in
`coordinate-work/open-items.md`. Covers lists AND the bind row.

### Cause 2 — filtered generators: dead choices are still minimised

`filtered even` is NOT the same bug: `lower_and_delete` costs 0 there,
and the cost is in `minimize_choices` at 95 against 37 for the same
generator shape unfiltered. 2.6x for adding a filter.

`G.filter` rejection-samples, so a 50%-accept predicate consumes ~2 tape
draws per accepted value. 37 x 2 = 74, in the region of the observed 95
— consistent with the shrinker spending its effort binary-searching
choices belonging to REJECTED draws, which cannot affect the final
value.

Hypothesis handles this with `remove_discarded()`, called at the top of
every `fixate_shrink_passes` iteration (shrinker.py, in the loop that
also does pass reordering), deleting choices that belong to discarded
draws. tapecheck's nearest pass, `delete_streams`, costs **0 on every
property measured** — there is no equivalent.

Fix: mark filter-rejected draws on the tape and delete them before
minimising. This is the measured justification for the "assume / filter
rewriting" item already queued under RO4.

### Two fixes, both already on the roadmap, both previously unjustified

Neither needs new infrastructure, and neither is pass reordering.

### Replication on a DISJOINT seed set

The first "500 trials confirms the 100-trial run" claim was weak: seeds
were `t * 1_000_003` for t in [0,500), which CONTAINS t in [0,100), so
~20% of the samples were the same runs and agreement was partly
guaranteed. Different seeds matter for a second reason too — generation
hits different large examples first, so the shrinker gets genuinely
different inputs rather than more of the same.

Re-run with `dune exec diag/where_do_calls_go.exe -- 5000`, i.e. seeds
5000..5499, disjoint from the original 0..499:

| property | dominant pass | first | disjoint |
|---|---|---|---|
| list, length >= 3 | `lower_and_delete` | 612 | 615 |
| list, sum >= 100 | `lower_and_delete` | 427 | 420 |
| filtered even | `minimize_choices` | 95 | 94 |
| bind | `lower_and_delete` | 40 | 36 |
| pair | `minimize_choices` | 19 | 19 |
| int uniform | `minimize_choices` | 37 | 38 |

Every conclusion holds. Largest wobble is `bind` at -10%, the smallest
number and therefore the noisiest, consistent with it being the row
closest to Hypothesis's own cost.

## CORRECTION: the linear-descent diagnosis was wrong

The section above blamed the list cost on `lower_and_delete`'s greedy
repeat loop stepping integers by one, and recommended the `find_integer`
galloping search. **Both were wrong, and implementing it proved it.**

Galloping descent was installed and measured. Result: lists completely
unchanged (612 and 427, identical), and `bind` regressed from 59 to 984
total calls. Reverted; the patch is kept at
`galloping-attempt-REJECTED.patch` as evidence.

Finer instrumentation, splitting `lower_and_delete` into its greedy
repeat loop versus its `s/i/k/j` scan:

| property | lower_and_delete | of which greedy | of which scan |
|---|---|---|---|
| int list, length >= 3 | 612 | **0** | **612** |
| int list, sum >= 100 | 427 | **0** | **427** |
| bind | 40 | 30 | 10 |
| filtered even / pair / int uniform | 0 | 0 | 0 |

The greedy loop contributes **nothing** on the list properties. The cost
is the scan: for every segment, every choice `i`, every block length
`k in 1..4` and every delete position `j`, one `attempt`. That is
O(choices^2 x 4). For ~11 choices, ~484 — consistent with the 612 seen.

`bind` is the only greedy-dominated row, which is exactly why the
galloping change moved it and nothing else, and why it moved it the
wrong way: when only small steps are accepted, halving from the full
range costs ~log(range) failures per successful step instead of 1.

### What the error was

The per-pass counter totals every attempt in the pass. I attributed
that total to one loop inside the pass without measuring that loop, then
built a fix for it. The same mistake as attaching a self-designed
positive control to a design: the measurement was real but it was not
measuring the thing the conclusion was about.

### Corrected next step

Not galloping, and not pass reordering — but the third Hypothesis
mechanism, **per-pass early exit** (`max_failures = 20` consecutive
failures ends a pass), is now directly relevant, because the list cost
is a mostly-failing quadratic scan. That was previously lumped in with
reordering and dismissed along with it; the dismissal was too broad.
Reordering is still useless here. Early exit is not.

Also worth pricing: whether the `i x j x k` cross-product needs to be a
cross-product at all.

## Two failed fixes, recorded so they are not retried

Both were implemented, measured, and reverted. Patches kept.

**1. Galloping descent** (`galloping-attempt-REJECTED.patch`). Aimed at
`lower_and_delete`'s greedy repeat loop stepping by one. Lists: no
change at all (612, 427). `bind`: regressed 59 -> 984. The greedy loop
turns out to contribute ZERO on the list properties; only `bind` is
greedy-dominated (30 of 40), which is why only `bind` moved, and it
moved the wrong way — halving from full range costs ~log(range)
failures per step when only small steps are accepted.

**2. Resume instead of restart the scan** (`resume-scan-NULL-RESULT.patch`).
`lower_and_delete` ends with `if !accepted then i := 0`, re-walking the
whole prefix after every acceptance; Hypothesis's
`prefix_selection_order` resumes from the last success instead. The
arithmetic fitted nicely — 16 acceptances x ~40 attempts per scan = ~640
against 612 observed — so this looked like the answer. Measured:
641 -> 638 and 456 -> 456. Quality unchanged at 100/100. Essentially
nothing.

A fitting arithmetic is not evidence. Two plausible mechanisms have now
been costed and neither is the cause; the scan is expensive for a reason
not yet identified. **The next step is more measurement, not another
fix**: instrument the scan's own loop bounds (how many segments, choices
and positions it actually walks, and how that evolves across sweeps),
rather than inferring the shape from totals.

## Where the ChoiceTree idea actually stands

Matthias's suggestion — beat the cross-product with random sampling, or
random shuffling if you want to stay exhaustive — is exactly what
Hypothesis does, and the shuffling variant is the right one here:
tapecheck's `converged` flag is only sound if a sweep genuinely covered
everything, so sampling would quietly make "converged" a lie.

`choicetree.py` implements it: a pass makes decisions through a
`Chooser`, the tree marks branches dead and knows when it is
`exhausted`, and `selection_order` is pluggable between
`prefix_selection_order` (deterministic, resumes from the last success,
"preferring to move left then wrapping around to the right") and
`random_selection_order` (uniform). Randomising changes the order, never
the coverage.

This remains the most promising direction, but it is infrastructure, and
the last two attempts show the cause is not yet understood well enough
to justify building it.

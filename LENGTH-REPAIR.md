# The length repair, and why lengthlist is still a frontier

`lengthlist` (jlink/shrinking-challenge) is `bind` a length `n` in
`[1,100]`, then a list of exactly `n` integers in `[0,1000]`, failing iff
some element is `>= 900`. The minimal answer is `[900]`. Hypothesis
reaches it 100/100; tapecheck reached it 73/100 at 256 calls.

This records what Hypothesis actually does, that tapecheck now has the
same mechanism, and why that did **not** close the gap — because the
blocker turned out to be pass order rather than the missing move, and
fixing the order costs a different guarded property.

## What carries lengthlist in Hypothesis

An ablation over seeds 0–99 of Hypothesis 6.152.9, counting all
test-function evaluations:

| configuration | optimal | mean evals |
|---|---|---|
| unmodified | 100/100 | 87.2 |
| `pass_to_descendant` off | 100/100 | 87.2 |
| `minimize_duplicated_choices` off | 100/100 | 87.2 |
| `redistribute_numeric_pairs` off | 100/100 | 87.2 |
| `lower_integers_together` off | 100/100 | 87.2 |
| `reduce_each_alternative` off | 100/100 | 87.2 |
| `reorder_spans` off | 100/100 | 90.2 |
| `try_trivial_spans` off | 100/100 | 84.9 (a net *cost* here) |
| **`minimize_individual_choices` off** | **14/100** | 64.1 |

And inside that pass, removing only the length-repair retry gives
**51/100**, with every failure of the form `[0,…,0,900]` — elements
zeroed, length never coming down.

Two conclusions worth stating plainly, because both contradict what I
expected before measuring.

**Spans are not load-bearing.** With `try_trivial_spans`,
`reorder_spans`, `pass_to_descendant`, `reduce_each_alternative` and
`minimize_duplicated_choices` all disabled *and* the span-derived blocks
excised from `try_shrinking_nodes`, Hypothesis still scores 200/200 at
90.6 evaluations against 87.2 stock. A shrinker with no span information
whatsoever solves this within 4%. The span machinery is worth about
three evaluations.

**It is not the continuation-bool encoding either.** Because
`min_size == max_size == n`, `cu.many` draws no boolean at all
(`utils.py:301-304`), so the choice sequence for a 3-element list is
literally `(3, 5, 900, 7)` — the same flat length-prefix-then-elements
shape tapecheck already records.

## The move

In `try_shrinking_nodes` (`shrinker.py:1146`):

> lower the integer at index `i` to `v` and replay; if the replay was
> *not* interesting but consumed `L` fewer choices than it was handed,
> retry with exactly the `L` choices immediately after `i` deleted.

The deletion size is **computed, never searched**. Its partner is a
replay convention rather than a pass: over-long attempts are truncated
and surplus trailing choices ignored, so lowering `n` also gets
right-truncation for free.

tapecheck's `lower_and_delete` is the same *idea* done the expensive
way: it lowers by **one** and then hunts for a deletable block, `j` over
the whole stream and `k` over 1..4. On a 200-choice tape, `n = 55 -> 1`
costs 54 lowerings each paying a search, and a lowering that drops more
than four choices cannot be expressed at all.

## What was actually missing, and what was not

Right-truncation was **already free**: an accepted candidate is
`out.Tape.image`, what the replay consumed (`tape.ml`'s `finish` returns
`Array.sub s.written 0 s.wlen`), so surplus trailing choices vanish by
construction. What was missing is deletion from the **front** of the
element region, which is what walks a late failing element leftward.

The signal was also already there and simply discarded:
`search_candidate` threw away `out.Tape.image` whenever the proposal was
uninteresting. It is now retained in `s_last_recorded`, and
`minimize_integer`'s `try_value` does the repair.

One bug worth recording, because it produces plausible garbage rather
than an error: `attempt` returns `false` both for "replayed and was not
interesting" and for "already seen, not replayed at all". Reading the
consumed length without clearing it first sizes the deletion from
whatever unrelated replay happened to run last. It is cleared before
every attempt.

## The measurement: it is inert, and the reason is pass order

Instrumented over 100 lengthlist trials, the repair fires **once**.

`minimize_integer` skips a choice already at its target, and in the
stock sweep `lower_and_delete` runs first and has already ground the
length prefix down one step at a time before `minimize_choices` ever
sees it.

Hoisting the lowering earlier does close lengthlist — and costs
`test_poison`:

| | stock order | `minimize_choices` first |
|---|---|---|
| **repair off** | lengthlist 73/100, 256 calls · poison 10/34 | lengthlist 7/100, 311 calls · poison **6/34** |
| **repair on** | lengthlist 74/100, 256 calls · poison 10/34 | lengthlist **100/100, 135 calls** · poison **6/34** |

Read the bottom-left and top-right cells together. The repair alone is
harmless and useless; the reorder alone is harmful and useless. Only
together do they close lengthlist, and the harm is unchanged.

So the poison regression is **not caused by the repair** — it is caused
by accepting bare lowerings early, and it is the same 6/34 with the
repair switched off.

Two further variants, both rejected:

- A dedicated integers-only repair pass in the same early slot measured
  identically (100/100 at 135, poison 6/34), confirming the damage is
  the position rather than the pass.
- A version that *probes* a lowering without accepting it, so only
  repaired proposals are ever taken, was worse on every axis: lengthlist
  76/100 at 373 calls, poison still 6/34, and the poison base tree
  drifted from 34 testable positions to 36.

## What ships

The mechanism, in `minimize_integer`, with the stock pass order. All ten
regression guards pass, `test_poison` is at 10/34 with its 34 positions
intact, and the full suite is green. lengthlist is 74/100 at 256 calls
against a 73/100 baseline — i.e. unchanged within noise.

Shipping an inert mechanism is a deliberate call: it is measured
harmless, it is the correct move, and the blocker is now a named and
quantified ordering problem rather than a missing capability.

## What would unblock it

The open question is an ordering — or an interleaving — under which the
length prefix is lowered in one jump *before* `lower_and_delete` grinds
it down, without granting every other integer the same early treatment.
`test_poison` is the constraint to satisfy, and 6/34 versus 10/34 is the
number to beat.

Worth noting what this is *not*: it is not a span problem. The ablation
above rules that out, so `sort_siblings` and the span work are not the
route here.

---

# Follow-up: the computed repair inside `lower_and_delete`

Branch `computed-repair`. **Not on master: it fails two cost guards.**

The 2x2 above concluded the blocker was pass order, and that hoisting
the lowering earlier closes lengthlist but costs `test_poison`. This
tries the third option: keep the pass order exactly as it is, and give
`lower_and_delete` the *computed* deletion size at its existing position
instead of searching for it.

It never accepts a bare lowering — that is what damaged poison. It
probes one to learn how many choices the replay consumed, then attempts
only the repaired proposal.

## Measured, n = 1000 paired

The first version of this table was n=100 with no variance quoted,
which cannot distinguish a real effect from noise. Redone properly:
**1000 independent random seeds** (master seed 20260802, recorded in
`~/prog/tapecheck-bench/seeds.txt`), the *same* seed list under both
arms so every comparison is within-seed, one worktree per arm.
Wilson intervals for rates, McNemar on the paired disagreements,
bootstrap CI (20 000 resamples) for the paired mean call difference.

| property | arm | fully minimal | 95% CI | mean calls | median | IQR |
|---|---|---|---|---|---|---|
| lengthlist | master | 719/1000 | 69.0–74.6% | 266.0 | 159 | 119–584 |
| lengthlist | **repair** | **990/1000** | **98.2–99.5%** | **126.6** | 130 | 82–173 |
| bind | master | 1000/1000 | 99.6–100% | 50.6 | 50 | 33–69 |
| bind | repair | 998/1000 | 99.3–99.9% | 80.0 | 79 | 45–114 |
| deep bind | master | 1000/1000 | 99.6–100% | 140.7 | 142 | 86–194 |
| deep bind | repair | 1000/1000 | 99.6–100% | 273.4 | 248 | 136–370 |
| listlen *(control)* | master | 1000/1000 | 99.6–100% | 148.3 | 150 | 145–152 |
| listlen *(control)* | repair | 1000/1000 | 99.6–100% | 149.3 | 151 | 146–153 |
| listsum *(control)* | master | 1000/1000 | 99.6–100% | 91.2 | 104 | 88–113 |
| listsum *(control)* | repair | 1000/1000 | 99.6–100% | 92.0 | 105 | 89–114 |

Paired differences (repair − master):

| property | quality | mean calls |
|---|---|---|
| **lengthlist** | 279 repair-only wins vs 8 master-only, **McNemar p = 8.6e-72** | **−139.3 [−152.0, −126.9]** |
| bind | 0 vs 2, p = 0.5 (not significant) | **+29.4 [+28.0, +30.8]** |
| deep bind | no disagreements | **+132.7 [+123.9, +141.7]** |
| listlen | no disagreements | +1.0 [+1.0, +1.0] |
| listsum | no disagreements | +0.8 [+0.7, +0.8] |

The lengthlist confidence intervals do not overlap and the effect is
about as unambiguous as this kind of measurement gets. The two cost
regressions are equally real — both intervals are far from zero — and
the two controls move by one call, which is the probe being paid once
and is the right order of magnitude for a change that should not touch
them.

Suite-level figures, n as built in: `test_poison` 10/34 → **12/34**,
`test_poison_lists` 22/48 → 20/48, `test_shrink_quality` 5/8 → 5/8.
Those are single runs over fixed case sets, so treat them as
indicative rather than measured; the 1000-seed table above is the
evidence.

### Two methodology errors worth recording

**The first table was n=100 with no variance.** Matthias caught it. The
direction survived (71.9% vs 99.0% brackets the 73 vs 99), but nothing
in that table justified believing it.

**My first 1000-seed run measured the wrong property.** I wrote a
`bind` from memory — `len in 1..10`, elements `0..100` — and it
reported a paired difference of −0.2 calls [−2.0, +1.7], i.e. "no
effect". The guard's actual bind is `len in 1..64` with elements
`0..1000`. With the real property the answer is +29.4 [+28.0, +30.8].
A confident null result about a property nobody was asking about.
The bench now copies the guard's definitions verbatim, including
`count = 200`.

lengthlist goes from a recorded frontier to one case short of
Hypothesis, at half the cost, and poison improves — the reorder made
poison *worse*, so the "keep the order" hypothesis was right.

## Why the cost rises, and why the obvious fixes do not work

The probe costs one evaluation whether or not it finds anything. Three
attempts to avoid paying it, all measured, all with no effect on the
numbers:

1. **A greedy repeat** after each success, matching the search path's.
   Identical results — the loop rarely fires twice.
2. **Earned probing** (spend 8 probes finding out whether the move pays
   here, then stop). Identical, because the cap never binds: the repair
   *does* succeed on bind, so it keeps its probe.
3. **Making it a fallback** after the j/k search fails. This fixes the
   cost completely — bind 53, deep bind 142, all guards green — and
   loses the entire gain, lengthlist back to 73/257. The fallback never
   fires there because the search *does* succeed, just slowly.

(3) is the one that explains the whole thing. On ordinary shapes the
deletable block sits at `j = i+1` and the existing search finds it in
**one** attempt; probing first spends two where one sufficed. The
computed repair only wins where the search is slow or cannot express
the deletion at all — further than the scan reaches, or larger than the
`k <= 4` cap — which is exactly lengthlist. The two are not orderable:
whichever goes first pays for the other.

## The decision this needs

Raising two cost bounds — bind 74 → ~90, deep bind 210 → ~280 — buys
lengthlist 73 → 99 and poison 10 → 12, and costs `test_poison_lists`
22 → 20.

Arguments for: the increases are 1.5-1.8x, where the regressions those
guards were built for were 3-20x (galloping took bind to 984), so both
would still catch their named failure at the higher bound. lengthlist's
own cost halves.

Argument against, and it is the repo's own standing warning: several
past changes looked obviously correct, held quality at 100/100, and
blew cost up 3-20x — which is precisely why cost is guarded at all.
Raising a cost bound to admit a change is the move that rule exists to
make deliberate.

Not landed. Needs a call.

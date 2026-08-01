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

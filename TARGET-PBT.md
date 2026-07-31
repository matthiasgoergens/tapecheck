# `target()`: what to port, from reading `optimiser.py`

Queued in `outreach/ro-roadmap.md` as RO4/RO7 and never started. Read
rather than guessed, because the useful parts are not in the idea.

Their own framing, worth keeping for the email — it is unusually modest:

> This implements a fairly naive hill climbing algorithm based on
> randomly regenerating parts of the test case. **It is not expected to
> produce amazing results**, because it is designed to be run in a
> fairly small testing budget, so it prioritises finding easy wins and
> bailing out quickly if that doesn't work.

Citation they give: Löscher & Sagonas, *Targeted property-based
testing*, ISSTA 2017.

## The four details that are not obvious from "hill climb"

**1. Lateral moves at equal score, gated on not growing the tape.**

```python
assert score == self.current_score
# We allow transitions that leave the score unchanged as long as they
# don't increase the buffer size. This gives us a certain amount of
# freedom for lateral moves that will take us out of local maxima.
if len(data.buffer) <= len(self.current_data.buffer):
```

A strict hill climber sticks on plateaus. Accepting equal-score moves
escapes them, and tying that to "the tape did not grow" keeps it from
wandering — it is the same shortlex instinct the shrinker uses, reused
as a tie-break. This is the piece I would not have invented.

**2. Walk blocks back-to-front, and restart on every improvement.**

```python
i = len(self.current_data.blocks) - 1
while i >= 0 and ...:
    if prev is not self.current_data:
        i = len(self.current_data.blocks) - 1   # improved: start again from the end
```

Plus a `blocks_examined` set so a restart does not redo work.

**3. Replace against the CURRENT best, not the starting case.** Their
comment: *"This helps ensure that if we luck into a good draw when
making random choices we get to keep the good bits."*

**4. Retry three times, for the same reason our `?realign` exists.**
*"in the event that there is some randomized component we want to give
it a couple of tries to succeed."*

And `max_improvements = 100`, because *"the target score may not be
bounded above"* — a termination condition that a maximisation loop
otherwise lacks entirely.

Note it uses `find_integer` for the value search, which we already have
(`engine/tape_engine.ml`), so that dependency is discharged.

## Porting shape

Blocks map to tape choices, `cached_test_function` to a replay-and-test,
`buffer` length to `Tape.image_size`. Nothing here needs spans, which
makes this one of the few Hypothesis features not blocked by
`SPANS-THE-ROOT-CAUSE.md`.

It does need a way for the test to report a score. Following Matthias's
interface suggestion from `MULTI-BUG.md` — a separate entry point rather
than a changed signature:

```ocaml
val run_target :
  ... -> test:('a -> bool) -> objective:('a -> float) -> 'a result
```

`run` is untouched, nothing existing pays for a feature it does not use,
and the two coexist.

## Why it is written up rather than built

The hill-climb loop itself is perhaps sixty lines, but it cannot reuse
the shrinker's machinery directly: `attempt`, `with_choice` and the
replay helpers are all local to `shrink`, closed over its `best`,
`budget_ok` and stats. A target optimiser needs the same primitives with
a different acceptance rule, so the honest first step is hoisting those
into something both can use — which is the same refactor
`MULTI-BUG.md` needs, for the same reason.

That makes an ordering argument: **hoist the replay/attempt primitives
once**, then multi-bug reporting and `target()` are both straightforward
on top. Doing either first without the hoist means doing it twice.

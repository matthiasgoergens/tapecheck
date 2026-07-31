# Shrink budget and shrink cost: what Hypothesis does, and what tapecheck should

Research note, 2026-07-31. Two questions from Matthias, both answered by
reading Hypothesis rather than inventing:

1. Should the budget count *successful* shrinks differently from failed ones?
2. Can the ~5.5x shrink-attempt overhead be reduced by trying candidates in a
   better order?

Yes to both, and Hypothesis has developed answers to each. Source references
are to `~/prog/python/hypothesis/hypothesis-python/src/hypothesis/internal/conjecture/`.

## Where tapecheck stands today

`engine/tape_engine.ml:320` does `Int.incr attempts` on **every** proposal, and
roughly fifteen shrink loops gate on `!attempts < budget`. Successful and failed
attempts are charged identically, and there is a single flat ceiling. That is
the opposite of Hypothesis on every axis below.

Measured consequence (`head_to_head/VERIFICATION.md`): 77.3 attempts vs
qcheck-stm's 13.9 on a property where the tape reaches the *same* minimal answer
— about 5.5x for no benefit. On the adversarial scenario the extra attempts are
the mechanism rather than waste, but the ordinary case is a real cost.

## Question 1: budget accounting

Three separate mechanisms, none of which tapecheck has.

**Only successes count against the shrink cap.** `MAX_SHRINKS = 500`
(`engine.py:45`), and `self.shrinks += 1` fires only when a strictly better
example is found (`engine.py:257`, guarded by
`sort_key(data.buffer) < sort_key(existing.buffer)`). Failed attempts never
touch it. Matthias's instinct, already implemented upstream.

**A stall counter that a success refunds completely.** `max_stall = 200`
(`shrinker.py:292`), checked as
`if self.calls - self.calls_at_last_shrink >= self.max_stall: raise StopShrinking()`
(`shrinker.py:414`). `calls_at_last_shrink` is reset on every success
(`shrinker.py:972`), so this bounds only the *current dry spell*, not total work.

**The stall tolerance adapts upward on success** (`shrinker.py:969-971`):

```python
self.max_stall = max(self.max_stall, (self.calls - self.calls_at_last_shrink) * 2)
```

A shrink that took 500 calls to find raises the tolerance to 1000. Their
comment: *"whenever we shrink successfully we give ourselves a bit of breathing
room to make sure we would find a shrink that took that long to find the next
time."* So the budget learns how patient this particular property needs it to be.

**Backstops.** Wall clock at 300s (`engine.py:903`) with a warning that asks the
user to report it as a performance bug; and `explain()` sets
`max_stall = 1e999` (`shrinker.py:503`), disabling the stall limit for a phase
that is *expected* to make no progress.

There is also a floor (`shrinker.py:705-708`) guaranteeing enough budget to
complete one full pass of `fixate_shrink_passes`, so the stall heuristic cannot
cut off before every pass has been tried at least once.

## Question 2: the 5.5x overhead

Reordering is the right idea and Hypothesis does exactly it, plus three more.

**Productivity-based pass reordering** (`shrinker.py:742-753`). After each loop
over the passes, score each: shortened the buffer `-1`, changed something `0`,
did nothing `1`; then `passes.sort(key=reordering.__getitem__)`. Productive
passes migrate to the front for the next loop.

**Per-pass early exit.** `max_failures = 20` consecutive failures ends that pass
for this loop. *"This implicitly boosts shrink passes that are more likely to
work."*

**Deterministic order with a random escape hatch.**
`sp.step(random_order=failures >= max_failures // 2)` (`shrinker.py:721`).
Deterministic ordering avoids repeat work; once half the failure allowance is
gone it starts jumping randomly to break out of a stall, and resumes
deterministic order wherever it lands.

**A `ChoiceTree` per pass** (`shrink_pass_choice_trees`, `shrinker.py:655`)
recording which choices within a pass are exhausted, so a candidate is never
proposed twice. For a pure-overhead problem this is likely the largest single
win, since repeated proposals are entirely wasted work.

Also `remove_discarded()` runs after every pass, and is switched off for the
remainder of the loop if it stops working — retried on the next loop.

## Suggested order of work

1. **Exhaustion tracking (ChoiceTree analogue).** Biggest expected win on the
   5.5x, and independent of the budget change.
2. **Success-only shrink cap + refunded, adaptive stall.** Replaces the flat
   `!attempts < budget` in every loop with one `keep_going ()` predicate
   checking total ceiling, stall, and success count together. Mechanical but
   touches ~15 sites, so it wants to be one focused commit.
3. **Productivity reordering and per-pass early exit.** Cheap once passes are
   first-class enough to be sorted.

Do not merge these into `stateful-testing`; budget policy lives on this branch.
Re-run `demo/shrink_table.exe` and `head_to_head` after each step — the
regression table (stock 0/100, tape 100/100) and the 300/300-vs-232/300 result
are the guards, and the shrink-cost column is the thing being optimised.

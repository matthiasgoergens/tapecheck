# Merging `statistics-and-health` into master: a plan, not a diff

Attempted twice and aborted twice. Not because it is hard, but because
the failure mode is silent, and this is exactly the class of bug that
took three wrong diagnoses to find earlier in the same session.

## Why it conflicts

The branch was cut before the shrinker work. Since then `tape_engine.ml`
gained `find_integer`, `lower_together`, the per-pass failure cutoff,
`finish_from_failure` / `resume`, the failure-database hooks and the
determinism check. Three conflicts:

| file | conflicts | nature |
|---|---|---|
| `test_bq/dune` | 1 | trivial: each side added a test name, keep both |
| `engine/tape_engine.ml` | 3 | both sides grew the same regions |
| `engine/tape_test.ml` | 6 | not yet examined |

## The three engine conflicts

1. **`no_stats`** — master inserted `find_integer` just above it; the
   branch expanded the record with `cases_valid`, `cases_invalid`,
   `cases_failed`, `shrink_discards`, `events`, `generate_time`,
   `run_time`, `shrink_time`, `warnings`. Resolution: keep both, no
   thought required.
2. **`finish_from_failure` vs `natural_example_choices`** — not a real
   conflict of intent. Master added `finish_from_failure` (shared tail of
   `run` and `resume`); the branch added `natural_example_choices`, the
   tape analogue of `HealthCheck.large_base_example`. Keep both.
3. **`run` / `resume` signatures** — master carries `~budget
   ~max_seconds ~max_shrinks ~max_stall ~max_pass_failures ~domains
   ~realign ~stats`; the branch adds `?health ?suppress_health_check`.
   Union of the two.

## The part that is NOT textual, and why this was aborted

The branch's counters have to be *fed*. Master added code paths that did
not exist when the branch was written:

- `finish_from_failure` — the shared tail now used by both `run` and
  `resume`. Does it update `cases_failed`, `shrink_time`?
- `resume` — an entire entry point the branch never saw. A resumed run
  that reports zero valid cases is wrong but looks fine.
- `run_with_db` — replays a stored tape before generating. Those replays
  are test calls; are they counted?
- `check_generator_determinism` — 8 extra replays on the failure path.
  Should those inflate `cases_valid`? Probably not, but it must be a
  decision rather than an accident.
- `lower_together`, and the cutoff's early exits — do they account
  `shrink_discards` consistently with the older passes?

Merge the text and the build goes green, the guard suite passes (it
checks shrink quality and cost, not statistics), and the reported
statistics are quietly wrong. Nothing in the current suite would catch
it, which is the whole problem.

## What doing it properly looks like

1. Resolve the three engine conflicts and `test_bq/dune` as above —
   mechanical.
2. Examine the six `tape_test.ml` conflicts (not yet looked at).
3. **Then**, before trusting it: write a statistics assertion test, the
   way `test_regression` guards shrink quality. Something like — run a
   property with known outcomes and assert `cases_valid + cases_invalid
   + cases_failed` equals the true call count, on `run`, on `resume`, and
   on a database-replay path. That test does not exist and is the actual
   deliverable; without it the merge is unverifiable.
4. Run the full suite plus that new test.

Step 3 is the reason this is a focused task rather than a tail-of-session
one. It also has independent value: the branch's own two bug fixes
(`assume`'s exception swallowed by `Or_error`, `data_too_large`
unreachable via double-counting) were both silent-undercount bugs, which
suggests the area is prone to them.

## Step 3 is now DONE: `test_stats_accounting/`

Written, and it immediately paid for itself by correcting me rather than
finding a bug.

My first version asserted that `stats.tests` equals every call to the
test function. It reported three failures — an all-passing run counting
0 despite 250 calls, and off-by-2 / off-by-1 elsewhere. That looked like
exactly the silent-undercount bug this plan predicted.

It was not. `stats.tests` is incremented in exactly one place, inside
the shrink path, and the type's own comment says why:

> **True cost of a shrink**, separate from the proposal-count budget:
> `[replays]` generation runs, `[tests]` test executions, ...

Generation is *deliberately* excluded. The engine is right; my ground
truth was wrong. Rewritten to assert the documented meaning, all four
now pass:

```
  ok  all passing: no shrink, so tests = 0        (250 generation calls, correctly uncounted)
  ok  run: tests = total - generation        106  (108 total, 2 spent finding the failure)
  ok  resume: tests = total - 1 confirmation  84
  ok  determinism check does not inflate tests  0 (8 replays, none counted as shrink work)
```

**And this sharpens the merge hazard rather than dissolving it.**
`tests` means shrink-phase work by design. The branch's `cases_valid`,
`cases_invalid`, `cases_failed` mean *all* cases — so they must be fed
on precisely the generation path that `tests` correctly ignores.
Copying the shape of `tests` accounting would give counters that are
silently zero on a passing run, which is the failure this test now
catches.

So when merging, extend this file with the mirror-image assertions:
`cases_valid + cases_invalid + cases_failed` must equal the *total* call
count, including generation, on `run`, `resume` and a database replay.

## Do it next

Every further change to `tape_engine.ml` makes this worse. It is the
same ordering cost as `MULTI-BUG.md`, and this branch is already the
oldest unmerged one.

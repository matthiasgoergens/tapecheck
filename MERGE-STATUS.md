# What is on master, and what is not

Updated 2026-07-31 after upstreaming.

## Merged and pushed

- **`budgets-and-resume`** (34 commits) — the shrinker investigation and
  everything that came out of it: the per-pass failure cutoff,
  `find_integer`, `lower_together` (the zig-zag defence), the failure
  database (`tape_db.ml`), non-deterministic generator detection, the
  `~domains` clamp, the regression guard, all the diagnostic probes, and
  the write-ups.
- **`stateful-testing`** (10 commits) — `Stateful`, `Bisim`, the
  per-operation mutual-raise health check and its adversarial tests, and
  the head-to-head against `qcheck-stm` with its independent
  verification.

Both merged cleanly. Full `dune test` passes on the merged tree: all
nine regression guards, the bisim health and adversarial assertions,
stateful shrink-coherence, resume, explain, round-trip, fn-shrink.

## NOT merged: `statistics-and-health`

Conflicts in three files, aborted rather than resolved at the end of a
long session:

```
CONFLICT (content): engine/tape_test.ml
CONFLICT (content): test_bq/dune
Recorded preimage for 'engine/tape_engine.ml'
```

The branch is RO6 work — `event()`/discard counting and Hypothesis's four
health checks — plus two real bug fixes made while building it:
`assume`'s exception being swallowed by `Or_error` wrapping (every
discard became a false failure), and `data_too_large` unreachable via
double-counting.

It conflicts because `tape_engine.ml` has changed a great deal on master
since that branch was cut — the cutoff, `find_integer`, `lower_together`,
the database hooks and the determinism check all landed after it. The
merge wants doing deliberately, with the guard suite as the check, not
squeezed in at the tail of a session.

Worth noting the ordering cost, which is the same one flagged in
`MULTI-BUG.md`: branches cut before the engine work get dearer to merge
the longer they wait. This one should go next, before anything else
touches `tape_engine.ml`.

## Also unmerged

- `experiment/try-both-realign` — 0 commits ahead of master; already in.
- `hypothesis-baseline` — deliberately separate, unrelated history. It is
  the Python comparison harness and does not belong in the OCaml tree;
  people who just want to use tapecheck should not get the Python
  baggage.

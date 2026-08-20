# Issue #1 — stats accounting: what it was, and verification that it is closed

A record of the investigation behind
[#1](https://github.com/matthiasgoergens/tapecheck/issues/1), written after the
fixes landed. State is recoverable from `git log`; this is the part that is
not — how the bug was found, why it hid, and what the reproducers are for if it
ever comes back.

**Verified closed at `4b9a619`** (see the numbers at the bottom).

## The symptom

`Tape_test.run ~report:`Summary`` printed a line that contradicted its own
return value:

```
  summary line : tapecheck: 12 cases (12 valid, 0 discarded, 0 failing)
  run returned : Error (... (input (5 5)) (error "a = b = 5"))
```

`0 failing` beside a returned counterexample reads as "the property held",
which is the opposite of what happened.

## Why it hid

`stats.cases_failed` was written in exactly one place — the generate-phase
accounting — while a failure could be *discovered* in four:

1. ordinary generation,
2. the correlated-value mutation,
3. the pooled batch path (`?domains > 1`),
4. replay (`?examples`, `?regressions`).

Only the first incremented the counter. The other three produced a returned
failure that the summary never saw. Worse, the total is computed as
`cases_valid + cases_invalid + cases_failed`, so the failing case went missing
from the total as well.

It hid because **the common path was the one that worked.** Anything found by
ordinary generation reported correctly, so the bug only appeared when one of
the other three discovery paths won the race — which for the mutation means
"when the property needs two draws to be equal".

## How it was found

Not by reading. tapecheck was wired into an unrelated project's property
suite ([binary-relations](https://github.com/matthiasgoergens/binary-relations),
branch `tapecheck-shrinking`) to replace `Shrinker.atomic`. The shrinker did
its job — on the one law that genuinely failed there it reduced the
counterexample to the minimal one — and the summary line was the only thing
that looked wrong.

The diagnosis was then **tested rather than assumed**. The correlated-value
mutation copies one integer choice's value over another with identical bounds,
so it can only manufacture a failure that needs the two draws to be *equal*.
That predicts a contrast, and the contrast held: two properties over the same
generator, failing at the same rate (1 in 36), 50 seeds each —

| property | reported `0 failing` while returning a counterexample |
|---|---|
| fails on EQUAL draws, `a = 5 && b = 5` | **30 / 50** |
| fails on UNEQUAL draws, `a = 5 && b = 0` | **0 / 50** |

## One thing that was *not* a bug

The small case counts on failing runs — `4 cases`, `12 cases` against
`test_count = 300` — are correct. Generation stops at the first failure, so
those are the number of cases actually run. Only the `failing` bucket, and the
total derived from it, were wrong. This is noted because it looked suspicious
and cost a second look.

## Verification at `4b9a619`

Reproducers are preserved in companion evidence
`experiments/stats-accounting-issue-1/legacy-2026-08/` (`repro.ml`,
`repro_paths.ml`, `dune`); drop them in as `repro_stats/` and
`dune exec repro_stats/repro_paths.exe`. Run against current `master`, with the
property failing on UNEQUAL draws so the mutation is ruled out:

```
  ?examples                    counted correctly   1 cases (0 valid, 0 discarded, 1 failing)
  ?regressions (replay run)    counted correctly   1 cases (0 valid, 0 discarded, 1 failing)
  Tape_engine.run ~domains:1   counted correctly  32 cases (31 valid, 0 discarded, 1 failing)
  Tape_engine.run ~domains:4   counted correctly  32 cases (31 valid, 0 discarded, 1 failing)

  ~domains:1, never fails      engine ran 300 cases; summary: 300 cases (300 valid, ...)
  ~domains:4, never fails      engine ran 300 cases; summary: 300 cases (300 valid, ...)
```

All four discovery paths count. The pooled path, which previously recorded
*nothing at all* — 300 cases run, 0 recorded, even on a passing run — now
records them. And the correlated-mutation sweep is `0/50` on both properties,
against `30/50` before.

## The general shape, worth keeping

The counter was a **diagnostic that silently read zero for a class of work**.
That is the dangerous kind: it does not fail, it under-reports, and it
under-reports exactly on the paths that are newest and least travelled. A
diagnostic that has stopped seeing something certifies its absence.

Two habits fall out, and both earned their keep here:

- When one counter is incremented at a *discovery* site, ask how many discovery
  sites there are. The fix moved the increment to where the engine *commits* to
  a failure, so a fifth path cannot silently reintroduce it.
- A regression test for this class should assert the *relationship* — a run
  returning `Error` never reports `0 failing` — rather than any particular
  count. Counts drift with unrelated changes; the invariant does not. That is
  what `test_stats_accounting` now checks.

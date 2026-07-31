# I have been reading a three-year-old Hypothesis

Caught by an external reviewer, and it is worth recording precisely
because a lot of this session's source archaeology rests on it.

## The two versions in play

| | version | date | used for |
|---|---|---|---|
| `~/prog/python/hypothesis` (git checkout) | **6.80.1** | 2023-07-06 | every source reading |
| venv in `tapecheck-hypothesis-baseline` | **6.164.0** | current | every benchmark |

So the **measurements are against current Hypothesis and stand**. The
**code archaeology was against 6.80.1** and needs checking case by case.

## What actually changed

6.164.0 is after the choice-sequence rework: "blocks" and "buffer"
became "nodes" and "choices", "examples" became **spans**.

| 6.80.1 (what I read) | 6.164.0 (current) |
|---|---|
| `lower_blocks_together` | **`lower_integers_together`** |
| `minimize_duplicated_blocks` | `minimize_duplicated_choices` |
| `minimize_individual_blocks` | `minimize_individual_choices` |
| `reorder_examples` | `reorder_spans` |
| `block_program` | `node_program` |
| `redistribute_block_pairs` | `redistribute_numeric_pairs` |
| `dfa_replacement` + `SHRINKING_DFAS` | **REMOVED** |
| — | `try_trivial_spans` (new) |
| — | `lower_duplicated_characters` (new) |
| — | `normalize_unicode_chars` (new) |

Survives unchanged in substance: `pass_to_descendant`,
`remove_discarded`, `find_integer`, `max_stall`, `MAX_SHRINKS`,
`interesting_origin`, `cu.many`.

## What this invalidates, and what it does not

**Invalidated:**

- **The learned-DFA item in `MINING-BACKLOG.md`.** I ranked L\* shrinker
  normalisation as the second-most-valuable unmined thing. It was
  *removed* from Hypothesis between 6.80.1 and 6.164.0. It is historical
  research, not a parity gap. The reviewer is right and this correction
  matters — I was about to spend real effort on it.
- **Names cited in the email.** `lower_blocks_together` does not exist
  in the version anyone will look at.

**Not invalidated:**

- Every measured number (benchmarks ran against 6.164.0).
- `find_integer`'s linear 1..4 scan, and the reasoning about escalation
  order — still present, still the reason my galloping patch failed.
- The zig-zag defence: still there as `lower_integers_together`, so the
  port is conceptually right.
- `cu.many` continuation bools — still how `ListStrategy` works.
- The span argument in `SPANS-THE-ROOT-CAUSE.md`. If anything it is
  *stronger*: current Hypothesis has moved further toward spans, and two
  of the three new passes (`lower_duplicated_characters`,
  `normalize_unicode_chars`) are semantic-primitive work that a flat
  int64/float/bool tape cannot express at all.

## The lesson, which is not "check versions"

I cloned a repository and read it for a day without once checking what
it was. The benchmark venv had the current version the whole time — the
two sat side by side and I never compared them. The specific failure was
not carelessness about versions; it was treating a checkout as
authoritative because it was *local*, when the pip-installed copy right
next to it was newer.

Practical fix, and it costs one command: before reading a dependency's
source for evidence, print its version and compare it to whatever the
project actually runs against.

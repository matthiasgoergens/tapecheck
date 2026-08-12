# Wave 2 checkpoint: discarded generation regions

Measured 2026-08-12 on `wave2/span-deletion`, after the explicit leaf-budget
checkpoint. This remains an experimental generator in `probe_list_design/`,
not a public Base Quickcheck API.

## Mechanism

Hypothesis retries a recursive draw from the advanced choice stream when it
exceeds `max_leaves`. The failed attempt has no influence on the returned
value, but Tapecheck previously retained every choice it consumed. In the
1,000-seed leaf-budget measurement, 102.96 of the capped generator's 119.41
mean choices belonged to such abandoned attempts.

The span seam now has a separate `discard_on_exception` capability. A
successful span is filtered out; an exceptional span is retained as runtime
metadata with its half-open choice range. The shrinker's `remove_discarded`
pass runs before global trivialisation and ordinary structural deletion. It
tries outermost discarded ranges first, restarts after every accepted edit,
and uses replay as the correctness oracle. Unmodified generators request no
discardable spans and therefore record no new metadata.

This differs deliberately from marking every recursive attempt as ordinarily
deletable: a successful attempt produced the value and cannot be erased, while
a rejected attempt is semantically dead input regardless of its first choice.

## Result

The deterministic recursive test still found all fifty failures and reached
the exact twenty-node boundary in all fifty. Compared with the immediately
preceding leaf-budget checkpoint:

| Capped recursive arm | Before | With discarded regions |
|---|---:|---:|
| Exact minima | 50/50 | 50/50 |
| Mean shrink attempts/failure | 168 | 154 |
| Mean choices in final failing tape | not recorded | 28 |
| `remove_discarded` proposals | unavailable | 46 total |

The fresh-generation tape remains 119.41 choices on average: discarded-region
removal is a shrink operation, not a change to the generated distribution or
recording format. The new probe reports 102.96 of those choices as discarded,
which explains why this specialised first pass is worthwhile despite its
modest effect on total shrink calls in this particular property.

The direct regression uses a tape containing one rejected attempt followed by
a successful failing attempt. It verifies that `remove_discarded` deletes the
rejected range, preserves the returned failing value, and leaves at most the
two choices needed by the successful attempt. Tape-level tests separately
cover exceptional retention and successful-span filtering.

## Limits and next step

This is a local capability, not yet the complete Hypothesis span model. The
runtime metadata is reconstructed on replay and is not persisted in the tape
database. Nested discarded regions prefer the outermost candidate and fall
back to contained regions if replay rejects that edit, while every accepted
deletion is still oracle-checked.

The list and recursion representation is now coherent enough to move from
probe code towards a reviewed Base Quickcheck generator patch. Before doing
that, the production API needs a decision on pathological non-terminating
`extend` functions and the OCaml-specific risk that `try ... with _` can catch
the private leaf-limit exception. First-class string and bytes choices remain
separate work.

## Reproduction

The complete deterministic output is
`probe_list_design/results/2026-08-12-discarded-regions.txt`. Reproduce it with:

```sh
nice -n 10 ionice -c 2 -n 7 opam exec --switch=5.3.0 -- \
  dune exec probe_list_design/probe_list_design.exe
```

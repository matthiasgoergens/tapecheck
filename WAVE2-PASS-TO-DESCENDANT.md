# Wave 2 checkpoint: pass to descendant

Implemented and measured 2026-08-12 on `wave2/span-deletion`.

## Implementation

The span seam now has an explicit `descendable` capability, separate from
whole-span deletion and exception-discard tracking. Tapecheck retains only
spans requesting one of those capabilities, so unchanged generators still do
not allocate observational span metadata.

`Generator.recursive_with_max_leaves` records every recursive value in a
same-labelled descendable span. Each span includes the strategy-selection
choice as well as the selected subtree, which makes a descendant's tape slice
valid input at an ancestor position. The new shrink pass considers properly
contained, same-labelled spans in the root stream (boundaries may share one
endpoint), replaces the ancestor slice with the descendant slice, and accepts
only a still-failing, shortlex-smaller replay. This first version is
root-stream only: generated
function streams rewind offsets at call boundaries, so interval containment
there is not sufficient proof of runtime ancestry without an additional call
epoch or parent identity. It tries the largest removals first and reconstructs
all offsets after every accepted proposal.

This is intentionally narrower than arbitrary block movement. Labels and
nesting are generator declarations of type compatibility; replay remains the
oracle for dependent draws and cross-stream effects.

## Poison-tree result

The existing port of Hypothesis's poisoned-tree test was run in two arms with
identical sizes, seeds, poison positions, search limits, and shrink budgets:

| generator | poisoned leaves promoted to the root |
|---|---:|
| unchanged, no recursive spans | 12/34 |
| same generator with descendable recursive brackets | **34/34** |
| Hypothesis | **34/34** |

The 34 cases enumerate every leaf position in two independently generated
trees of sizes 2, 5, and 10. Poison is a pair of maximum 16-bit values which
fresh generation is overwhelmingly unlikely to rediscover, and a trailing
maximum marker prevents suffix truncation from satisfying the property. The
structural arm must preserve and relocate the chosen descendant; it cannot
generate a replacement poison. `test_poison/test_poison.ml` now asserts both
the unchanged 12/34 floor and the structural 34/34 result.

## Calculator follow-up

The pre-pass paired calculator sample is retained in
`diag2/calculator-structural-100.tsv`; the same 100 seeds after this pass are in
`diag2/calculator-descendant-100.tsv`. Discovery remains 100/100. The
structural arm moves from 501.3 to 438.6 mean replay attempts, 5.6 to 5.0 mean
nodes, and 37.7 to 35.4 mean rendered bytes. Exact canonical renderings move from
1/100 to 0/100, far too sparse to distinguish a real change from seed-level
variation and not evidence of a regression.

The important distinction is structural: descendant promotion now removes
every inert recursive wrapper, but the five-node calculator residue can still
have the wrong operator or literal arrangement. That remaining normalisation
work belongs to choice minimisation, sibling reordering, and eventually
duplicate-span handling—not to another descendant pass.

## Next work

The next span-dependent candidates are `reorder_spans` and
`minimize_duplicated_choices`. Before enabling either generally, restrict them
to explicit generator capabilities and measure the known `bound5`,
`large_union_list`, calculator, and poison-tree trade-offs on paired seeds.
First-class string and bytes choices remain an independent high-value gap.

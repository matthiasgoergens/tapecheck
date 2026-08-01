# A span-free approximation of `reorder_spans`: prototype and results

Built to answer whether the normalisation we lose to missing spans can
be partly recovered without them. Short answer: **yes for one challenge,
dramatically, but only in combination with the `non_uniform` patch — and
it makes the challenge that motivated it worse.** It is committed and
**disabled by default**.

## What Hypothesis does, and why it is canonical

`reorder_spans` sorts the children of a span that share a *label*, using
`sort_key` — shortlex over the choice sequence. Their docstring gives
the motivating case:

> `@given(st.text(), st.text())` with `assert x != y` — "Without the
> ability to reorder x and y this could fail either with `x=""`,
> `y="0"`, or the other way around. With reordering it will reliably
> fail with `x=""`, `y="0"`."

So the canonical arrangement is the *sorted* one, and normalisation —
reporting the same counterexample every run — is the benefit. This is
worth stating because the alternative was tempting: on `bound5` several
permutations are equally small, and we could have declared the score
unfair and counted any of them. That would have flattered the number
while measuring less.

## The approximation

`reorder_spans` needs span boundaries and labels. We have neither. The
stand-in is the one `correlate_image` already uses for single choices —
"equal bounds means the generator drew them from the same range" —
lifted to subsequences:

1. For window lengths 1..8, group positions by **signature**: the
   sequence of `(kind, lo, hi)` over the window.
2. Take a greedy non-overlapping subset of each group.
3. Propose those windows **sorted** by the existing `compare_shortlex`.

One proposal per (length, signature) group rather than per pair, so a
group of *k* siblings costs one attempt, not *k²* swaps. It carries its
own consecutive-failure cutoff, at the same constant as the other
passes.

## Results, Shrinking Challenge

`patch` is `proposals/base_quickcheck-non_uniform.patch`;
`target-aware` is the variant that orders branches by distance from the
shrink target. Stock and `+patch` at n=1000, the combinations at n=200.

| challenge | stock | +sort | +patch | +patch +sort | +target-aware +sort |
|---|---|---|---|---|---|
| reverse | 0.0% | 0.0% | 45.2% | 50.5% | 50.5% |
| **distinct** | 0.0% | 0.0% | 11.6% | **69.5%** | **69.5%** |
| large_union_list | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% |
| bound5 | **15.9%** | 12.5% | 5.2% | 0.0% | 8.5% |
| calculator | 1.7% | 1.5% | 1.5% | 2.0% | 2.0% |
| lengthlist | 68.3% | 71.5% | 68.3% | 71.5% | 71.5% |
| difference ×3 | 100% | 100% | 100% | 100% | 100% |

Cost, mean evaluations: `large_union_list` 1296 stock → 1590 with the
pass alone → 1479 combined. `bound5` 267 → 203 under target-aware+sort.

All ten regression guards pass with the pass enabled, costs unchanged.

## Reading it

**The headline is `distinct`: 11.6% → 69.5%**, with distinct answers
collapsing from 34 to 4. That is the mechanism working exactly as
designed — a list's elements are same-signature siblings, so sorting
them canonicalises the answer.

**On stock it does nothing and costs 23%.** Instrumenting `bound5`
showed why, and the reason is the same defect the `non_uniform` patch
addresses. A final tape:

```
I1[0,1] F0.00 | I0[0,1] | I0[0,1] | I0[0,1] | I1[0,1] F0.10 I-1[-32768,32767]
```

The first non-empty slot is two choices — `F0.00` took the `return lo`
shortcut and produced `-32768` with no further draw. The last is three,
via the general branch, producing `-1`. **Structurally equivalent
siblings with different tape shapes**, so signature matching can never
group them. The shortcut branches defeat shortlex ordering and sibling
detection by the same means.

**`bound5` is not rescued, and the reason is instructive.** With the
patch the two slots do share a signature and are grouped — and sorting
compares the *selector* first, where `-32768`'s ≈0.0 beats `-1`'s ≈0.5.
The selector problem again, now inside the segment comparison.
Target-aware ordering recovers part of it (0% → 8.5%, and cost 274 →
203) but stays below stock's 15.9%.

So `bound5` has now resisted three separate attempts, each failing for
the same structural reason: whatever we put first in the recording
dominates the comparison, and none of our knobs can make the *value*
dominate without disturbing something else. Spans would make the
subtree the unit of comparison, which is the point.

## Status

Committed, `sort_siblings_enabled = false` in `tape_engine.ml`. It is a
net negative against the stock vendored `base_quickcheck` we build
against, and a large win only in a combination we do not ship. Turn it
on together with the patch to reproduce the table.

Two things would change the calculus: the `non_uniform` patch landing
upstream, or a sharper notion of "sibling" than equal bounds — the
current heuristic both misses real siblings (variable-length ones, whose
signatures differ *because* their contents differ, which is most of
`large_union_list`) and groups unrelated draws that happen to share
bounds.

# Wave 2 checkpoint: continuation-encoded lists

Measured 2026-08-10 on `wave2/continuation-lists`.  The executable in
`probe_list_design/` compares the stock Base Quickcheck list generator with
two experimental designs.  It is a design probe, not a public API.

## The design being tested

Hypothesis does not draw a final list length and then redistribute a shared
size budget.  It makes a weighted continuation decision before each element,
wraps each element in a structural span, and controls recursive growth with a
separate leaf budget.

The closest migration path for Base Quickcheck need not change its marginal
length distribution.  Its current log-uniform length law can be factored into
conditional continuation probabilities:

```
P(continue after k elements | length >= k)
```

The experiment records those decisions first, then generates elements from a
left-to-right running budget.  Only optional elements (`length - min_length`)
are charged to the budget, matching Base's existing invariant.  Unused budget
is left unused, because exact redistribution and a suffix-stable prefix cannot
both be maintained.

## What the experiment ruled out

A continuation decision represented as `unit_float < p` is not an adequate
tape choice.  It distorts Tapecheck's edge-biased generation and turns a
structural false/true decision into numerical threshold search.  In the first
100-seed run it found the exact `[100]` minimum for `sum >= 100` only 49 times
and averaged 351 shrink proposals.

An integer approximation was worse: 6 exact minima and 1,895 proposals.  A
large integer range gives the edge-biased integer sampler and integer passes a
structure they were not designed to interpret as a Boolean.

The provisional `Splittable_random.bool_with_probability` seam records the
result as a real `Bool` tape choice while retaining the requested generation
probability.  This is the right *kind* of choice; the exact API and probability
metadata still need adversarial review before an upstream proposal.

## Results

At size 10 over 20,000 raw (unattached) samples, stock and continuation
lengths had means 3.591 and 3.579.  Their two-sample chi-square statistic was
7.68 over eleven bins.  This is consistent with preserving the current
length law; a larger deterministic distribution test should replace this
smoke measurement before shipping.

The weighted-Boolean version gave the following 100-seed shrink results:

| Property and exact minimum | Stock | Upfront length + running budget | Continuation + running budget |
|---|---:|---:|---:|
| `length >= 3`, `[0; 0; 0]` | 100/100, 151 proposals | 100/100, 201 | 92/100, 108 |
| `sum >= 100`, `[100]` | 100/100, 94 | 99/100, 51 | 54/100, 114 |
| `hd = length`, `[1]` | 47/100, 131 | 74/100, 103 | 46/100, 84 |
| ten strings, ten empty strings | 0/100, 369 | 0/100, 304 | 0/100, 380 |

The proposal count is averaged over all 100 seeds.  All variants found a
failure in every row except the stock and upfront-length `hd = length` cases,
which found 98 and 99 respectively.

Generation remains bounded by the corrected running budget.  At size 50 over
10,000 samples, maximum total string payload and maximum recursive tree node
count were both 50 for all three variants.  Continuation trees averaged 8.65
nodes against stock's 9.50.

## Decision

Do not ship the continuation list rewrite on its own.  It can cheaply remove a
suffix, but it cannot remove irrelevant elements before the element that
causes the failure.  The `sum >= 100` regression is the cleanest witness: when
the decisive value is late in the list, suffix shortening cannot isolate it.

Hypothesis solves both halves together: continuation choices make length
structural, while per-element spans allow deletion of arbitrary elements.
The next implementation step is therefore the span seam and an element-span
deletion pass.  Re-run this exact probe after that pass.  The list rewrite is
ready to reconsider only if arbitrary deletion recovers the exact-minimum
regressions as well as the poison-list score.

The recursive-complexity contract remains separate.  Following Hypothesis
means introducing an explicit local cap (analogous to `max_leaves`) rather
than making list length carry a global, implicitly shared size resource.

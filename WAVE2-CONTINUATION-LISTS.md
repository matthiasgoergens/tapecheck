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

## Span-hook cost

The first implementation used separate start/stop calls and paid an
`Exn.protect` for every list element, even when no engine was attached.  That
was measurably noisy and sometimes several per cent slower.  The revised seam
is one bracket:

```ocaml
Splittable_random.with_span random List_element ~f
```

Its `None` fast path calls `f` directly; only an attached observer pays for the
callbacks and exception-safe closing.

The original min-of-repetitions benchmark was withdrawn.  On a shared machine
it hid roughly two-fold changes in processor speed, so its apparent 0--2%
effect was not trustworthy.  `bench_spans/` now uses 60 randomised paired
blocks, with short treatment arms, warm-up, identical deterministic workloads,
and all observations retained.  The primary estimate is the mean paired log
ratio with a 95% Student-t interval.

Pinned to logical CPU 31, 60 blocks of 30,000 size-30 lists estimated the
unused bracket at -0.23%, with a 95% interval from -0.63% to +0.17%.  The
un-pinned control run had an interval from -3.29% to +4.08% and several gross
within-block frequency transitions, demonstrating why affinity and blocking
matter here.  The evidence therefore rules out a large steady-state cost on
this machine, but does not establish a literal zero cost or a speed-up.  An
upstream proposal should report the design and interval, not merely a point
estimate; repeat it on the maintainers' target hardware.

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

## Adversarial-review boundary

The current commit is a seam, not span-aware shrinking.  `List_element`
surrounds only the draws made by the element generator.  Base still draws the
final length and all size-allocation/permutation choices before those spans.
Deleting one current span alone therefore leaves the generator expecting the
same number of elements and normally overruns.  A useful list representation
must put the continuation decision and element in the same structural unit,
as Hypothesis does, or define an explicit compound edit.  Merely recording the
new callbacks would not close the quality gap.

The provisional weighted Boolean records only its result, not the probability
parameter.  For probabilities strictly between zero and one, either Boolean
remains a valid replay choice even if a preceding edit changes the requested
probability; zero and one are forced and consume no choice.  This is sufficient
for the continuation probe, but an upstream API should decide explicitly
whether probability is sampling metadata only or part of replay validity.

`with_span` guarantees a stop callback when the body raises, and tests nested
and exceptional bodies.  It assumes observer callbacks themselves do not
raise; otherwise a failing stop callback may mask the body's exception.  Make
that callback contract explicit before publishing the seam.

Finally, the benchmark's tight interval depends on CPU affinity.  Without
affinity, processor-frequency transitions made the result unresolved.  The
reproducible command used here was:

```sh
nice -n 10 ionice -c 2 -n 7 taskset --cpu-list 31 \
  _build/default/bench_spans/bench_spans.exe
```

Logical CPU 31 is a machine-specific choice, not a portable default.

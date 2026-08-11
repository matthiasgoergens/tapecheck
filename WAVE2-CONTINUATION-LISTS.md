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

For the fresh hardening replication, the question is whether the unattached
bracket changes steady-state generation cost by a practically relevant amount.
The estimand is the paired geometric mean ratio of nanoseconds per generated
element; one randomised treatment pair is the analysis unit.  Processor
frequency, thermal state, scheduler activity, GC state, and treatment order are
the expected nuisances.  The fixed design is 60 balanced, randomly ordered
blocks of 30,000 lists after warming both paths, on one pinned logical CPU.  A
95% interval wholly inside +/-1% was the predeclared symmetric equivalence
criterion.  No blocks are excluded.  Timing uses monotonic process CPU time
(`Unix.times`), so
descheduling by unrelated work is outside the estimand while clock-frequency
changes remain a nuisance.  Because all blocks come from one process and
machine, a positive result is machine-local and still needs fresh-process and
upstream hardware replication before generalising.

Pinned to logical CPU 31, 60 blocks of 30,000 size-30 lists estimated the
unused bracket at -0.23%, with a 95% interval from -0.63% to +0.17%.  The
un-pinned control run had an interval from -3.29% to +4.08% and several gross
within-block frequency transitions, demonstrating why affinity and blocking
matter here.  The evidence therefore rules out a large steady-state cost on
this machine, but does not establish a literal zero cost or a speed-up.  An
upstream proposal should report the design and interval, not merely a point
estimate; repeat it on the maintainers' target hardware.

The predeclared hardening replication using process CPU time estimated -0.62%,
with a 95% interval from -0.98% to -0.27%; that interval is wholly inside the
+/-1% equivalence margin.  Two fresh-process sensitivity runs, added after
seeing the primary result, estimated -0.59% [-0.98%, -0.20%] and -0.41%
[-0.84%, +0.02%].

Adversarial review then ran four more fresh processes.  They estimated -0.46%
[-1.04%, +0.13%], -0.39% [-0.74%, -0.05%], -0.80%
[-1.04%, -0.56%], and -0.68% [-1.11%, -0.24%].  Only one of those four met
the symmetric equivalence criterion, so the original three-for-three result
was not robust: across all seven process-CPU runs, four met it and three did
not.  Raw reviewer observations are stored under `bench_spans/results/`.
The first three runs predated that results directory and unfortunately survive
only as these aggregates.

Every two-sided upper confidence bound was at or below +0.13%, however.  Using that
conservative bound, all seven runs exclude a slowdown of +1%, which is the
actual upstream risk posed by an unused hook.  This one-sided non-inferiority
interpretation was adopted after seeing the equivalence instability and is
therefore labelled post-review, not predeclared.  The executable reports both
claims separately.

All eight estimates including the earlier wall-clock run are negative.  An
added branch is not plausibly an optimisation, so the persistent direction is
probably a binary-layout or similar systematic effect that the within-binary
interval does not model.  Do not claim a speed-up or literal zero cost, and
repeat on separately built binaries and upstream hardware before generalising.

## Results

At size 10 over 20,000 raw (unattached) samples, stock and continuation
lengths had means 3.591 and 3.579.  Their two-sample chi-square statistic was
7.68 over eleven bins.  This is consistent with preserving the current
length law; a larger deterministic distribution test should replace this
smoke measurement before shipping.

The weighted-Boolean version gave the following 100-seed shrink results:

| Property and exact minimum | Stock | Upfront length + running budget | Continuation + running budget |
|---|---:|---:|---:|
| `length >= 3`, `[0; 0; 0]` | 100/100, 151 proposals/failure | 100/100, 201 | 92/100, 108 |
| `sum >= 100`, `[100]` | 100/100, 94 | 99/100, 51 | 54/100, 114 |
| `hd = length`, `[1]` | 47/100, 134 | 74/100, 104 | 46/100, 84 |
| ten strings, ten empty strings | 0/100, 369 | 0/100, 304 | 0/100, 380 |

Proposal counts are shrink attempts averaged over seeds that found a failure;
generation work for seeds that found none is deliberately not conflated with
shrinking work.  The earlier table divided by all 100 seeds and therefore
understated the conditional shrinking cost when found rates differed.  All
variants found a failure in every row except the stock and upfront-length
`hd = length` cases, which found 98 and 99 respectively.
Conditioning cost on finding a failure can itself select different seeds when
found rates differ; here the rates are 98--100%, so that effect is negligible.

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
raise.  A start-callback exception prevents the body; a stop-callback exception
propagates; and if both body and stop callback raise, Base's `Exn.Finally`
preserves both.  The interface now states and tests this contract, and the
end-to-end test also verifies that
`Generator.list_with_length` emits one balanced span per element.

`Intercept.t` is itself an unpublished experimental seam: the v1 proposal in
`splittable_random` PR #2 has not merged or shipped.  Wave 2 therefore treats
the additional weighted-Boolean and span callbacks as a replacement proposal,
not as a compatibility promise between two prototypes.  Before any upstream
release, either freeze the accepted record shape or hide construction behind
an API that can grow optional capabilities without breaking implementors.

Finally, the benchmark's tight interval depends on CPU affinity.  Without
affinity, processor-frequency transitions made the result unresolved.  The
reproducible command used here was:

```sh
nice -n 10 ionice -c 2 -n 7 taskset --cpu-list 31 \
  _build/default/bench_spans/bench_spans.exe
```

Logical CPU 31 is a machine-specific choice, not a portable default.

## Work queue after this checkpoint

Merge this seam only after its contract, end-to-end span test, measurement
accounting, provenance check, and adversarial review are green.  It remains
infrastructure rather than a claimed shrink-quality improvement.

PR #20 is a historical Wave 2 design snapshot whose inferred-string sequence
is explicitly superseded by the later list probe; do not merge it unchanged.
PR #29 remains a useful measured comparator for the running-budget policy, not
the selected public list implementation.

The next implementation branch should record span boundaries at runtime and
add one span-deletion pass, together with an experimental generator in which a
list continuation decision and its element occupy the same span.  Compare that
combined design with stock and PR #29 before replacing `Generator.list`.

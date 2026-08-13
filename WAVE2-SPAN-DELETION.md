# Wave 2 checkpoint: recorded spans and structural deletion

Measured 2026-08-11 on `wave2/span-deletion`. This is the first runtime use of
the span seam merged in PR #30. It remains experimental: the public
`Base_quickcheck.Generator.list` implementation is unchanged.

## What is implemented

`Tape.finish` now returns explicitly deletable runtime span metadata alongside
the serialisable choice image. A retained span is a half-open choice range
within one keyed stream and records the generator label's runtime
extension-constructor ID and its stream and choice offsets. Observational spans
are not retained because no current pass consumes them.

Spans are deliberately not serialised. They are generator-owned runtime
structure, reconstructed deterministically on replay. Accepted sequential and
pooled proposals carry their reconstructed spans with the winning image, so a
later pass never acts on stale offsets.

The first deletion pass is intentionally conservative. It considers only leaf
spans marked `deletable` whose first choice is `Bool true`, tries complete spans
back-to-front, and restarts from freshly replayed spans after every success.
Existing Base list element spans are observational and are filtered before
allocating runtime metadata, so they add neither shrink proposals nor a sort in
`Tape.finish`. The experimental list arm marks a continuation decision plus
its element as one deletable span.

This checkpoint established the representation and one useful, well-bounded
edit. `remove_discarded` and `pass_to_descendant` have since landed on this
branch; see `WAVE2-DISCARDED-REGIONS.md` and
`WAVE2-PASS-TO-DESCENDANT.md`. Span reordering remains open.

An initial implementation retained and sorted every observational Base-list
span. A randomised paired-block measurement at fixed length 30 estimated a
13.17% attached-tape CPU cost per element, with a 95% interval of
12.62%--13.72%, beyond the predeclared +5% materiality threshold. That design
was rejected. Its individual observations were not retained, an experimental
recording failure noted here rather than reconstructed.

With observational spans filtered, two processes using the initial benchmark
binary estimated the production callback body against callback no-ops at
-0.59% [-1.17%, +0.00%] and +0.12% [-0.34%, +0.58%]. A length-1,000
sensitivity run from that binary estimated -0.20%
[-1.25%, +0.87%]. All exclude the predeclared +5% slowdown on this machine;
none establishes zero cost or a speed-up. After a label-only source edit and
rebuild, a final length-30 process estimated -4.19% [-4.70%, -3.68%]. It is not
a third replication of the same binary; its implausibly large negative effect
reinforces the binary-layout caveat. Both arms already pay the span seam's
dispatch and `Exn.protect` costs, so this estimand isolates only the callback
body changed here. Raw paired observations and the benchmark design are in
`bench_span_recording/results/`.

## Forced choices are structural nodes

The previous seam said probability-zero and probability-one booleans should
bypass interception. That is wrong for a Conjecture-style replay tree.
Hypothesis's `many.more()` starts an element span and calls `draw_boolean` even
at `max_size`, using `forced=False`; its shrinker retains forced nodes and
separately avoids treating an all-forced span as a deletion target:

- <https://github.com/HypothesisWorks/hypothesis/blob/master/hypothesis-python/src/hypothesis/internal/conjecture/utils.py>
- <https://github.com/HypothesisWorks/hypothesis/blob/master/hypothesis-python/src/hypothesis/strategies/_internal/collections.py>

`bool_with_probability` therefore now reports forced decisions to an attached
interceptor without advancing the RNG. Replay consumes the Boolean node but
constrains its output to the forced value. This terminal false node is what lets
deleting an earlier element from a maximum-length list realign cleanly instead
of overrunning at the end. A focused regression pins that exact case.

## Exploratory comparison

The experimental unit is one deterministic seed, paired across generator
arms. The comparison uses 100 seeds per shrink property, size 10, the existing
200-case discovery limit, and the engine's default shrink budget. Outcomes are
exact-minimum counts and mean shrink attempts conditional on finding a failure.
These were exploratory measurements used to debug the representation, not a
preregistered confirmatory experiment.

| Property and exact minimum | Stock | PR #29-style running budget | Continuation prelude | Continuation + spans |
|---|---:|---:|---:|---:|
| `length >= 3`, `[0; 0; 0]` | 100/100, 151 | 100/100, 201 | 92/100, 108 | **100/100, 41** |
| `sum >= 100`, `[100]` | 100/100, 94 | 99/100, 51 | 54/100, 114 | **100/100, 25** |
| `hd = length`, `[1]` | 47/98, 134 | 74/99, 104 | 46/100, 84 | **99/99, 13** |
| ten strings, ten empty strings | 0/100, 369 | 0/100, 304 | 0/100, 380 | 0/100, 1883 |

Each fraction is exact minima over failures found; attempts are per found
failure. The combined representation completely recovers the three integer
list minima in this sample and uses substantially fewer proposals. During
exploratory development, before forced terminal nodes, five `sum` seeds stopped
at nine zeros followed by 100; that intermediate raw output was not retained.
After matching Hypothesis's forced-stop representation they all reached
`[100]` in the retained run.

The string row is not a contradiction. Its property requires retaining ten
elements, so deletion cannot help; first-class string/bytes choices and passes
remain a separate gap. Its high cost also reflects the deliberately unsafe
element-size policy below.

## Distribution and the missing recursive cap

The structure-only arm generates each element independently at the ambient
Base size. This isolates continuation and spans while preserving the intended
*untaped* length law. Over 20,000 size-10 raw samples, mean lengths were 3.591
for stock, 3.579 for the continuation prelude, and 3.599 for continuation plus
spans. Taped means were 3.554, 3.579, and 3.580 respectively. Tape-attached
generation deliberately uses edge-biased choices, so equality of the taped
sampling distributions is neither claimed nor established by those means.

It is not shippable. At size 50, total string payload averaged 479.49 and
reached 2,179, versus stock's mean 27.03 and maximum 50. Recursive trees were
deliberately not sampled because passing the ambient size independently to
every child can branch explosively.

An earlier combined attempt reused Base's running element budget as a stop
condition. It kept payload bounded but collapsed mean size-10 list length to
1.96, coupling collection length to element complexity again. That negative
result is the same non-orthogonality Hypothesis's design avoids.

Following Hypothesis therefore requires two separate mechanisms:

1. continuation choices and deletable element spans for list structure;
2. an explicit local recursive leaf cap, analogous to `recursive(max_leaves)`,
   which does not make list length share an implicit global size resource with
   element complexity.

Do not replace the public list generator until the second mechanism exists and
the combined design passes shrink-quality and generation-tail guards.

## Verification boundary

Focused tests cover filtering observational spans, nested deletable-span
recording, replay reconstruction, explicit deletion capability, observational
children inside a deletable parent, exceptional callback balancing,
forced-node recording, forced replay constraints, arbitrary leading-element
deletion, and deletion from a maximum-length list. The vendor patch is
regenerated from and checked against pinned `splittable_random` v0.17.0; the
Core consumer snapshot is generated from the same canonical sources.

The next step is the explicit recursive leaf-budget prototype. After that,
rerun this paired comparison, the poisoned-list/tree suites, and the full
Shrinking Challenge before considering a public generator rewrite.

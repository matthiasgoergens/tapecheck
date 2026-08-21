# tapecheck: choice-tape shrinking for base_quickcheck

In property-based testing
([QuickCheck](https://hackage.haskell.org/package/QuickCheck),
[Hypothesis](https://hypothesis.readthedocs.io/), and in OCaml
[base_quickcheck](https://github.com/janestreet/base_quickcheck)), you
state a property ("decoding an encoded message returns the original")
and the library checks it against hundreds of randomly generated
inputs. When an input fails, the raw random value is usually big and
noisy: a 40-element list of nine-digit numbers, where the actual bug
only needs `[100]`. *Shrinking* is the automated search for a smaller,
simpler input that still fails, and it makes the difference between a
counterexample you debug in a minute and one you stare at for an
afternoon.

Shrinking is hard to do well, because a shrinker that edits values
directly knows nothing about the *generator* that produced them (the
recipe turning random draws into your test inputs): halve an even
number and you may hand an odd one to a test that assumed evenness.
tapecheck takes a different route, ported from [Python
Hypothesis](https://hypothesis.readthedocs.io/):
record every random decision the generator makes as a typed, bounded
choice on a tape; shrink by editing the tape and running the generator
again on it, accepting an edit only if the test still fails and the
recording got shorter or simpler. A shrink proposal can never violate
a generator invariant, because a proposal is not a value: it is an
input to your own generator. Existing property-test call sites,
including those using everything `[@@deriving quickcheck]` produces,
can participate by changing the test runner rather than rewriting the
generator expression.

The adoption claim is deliberately asymmetric: Wave 1 is useful on its own
and requires no changes to existing generator implementations; Wave 2 is an
natural follow-up in which small structural changes improve selected shrinking
results further. Its APIs are introduced opt-in so compatibility can be
measured, not because the existing list representation is the intended end
state.

There are two deliberately distinct stages of this work:

- **Wave 1**, preserved at commit `695082c`, is the unchanged-generator
  proof. It records below `base_quickcheck`'s generator layer and shows
  that existing generator implementations can shrink without structural
  annotations.
- **Wave 2**, which is the current `master`, explores the gains from
  changing that layer as well. Ordinary list generation now records
  observational element spans, and new opt-in APIs provide continuation-
  based structural lists, leaf-bounded recursion, and reorderable spans.
  Existing property call sites remain source-compatible, but the vendored
  generator implementation is no longer unmodified.

This is a port of the [Conjecture
model](https://hypothesis.works/articles/how-hypothesis-works/) (the
engine inside [Python
Hypothesis](https://github.com/HypothesisWorks/hypothesis)) to OCaml,
sibling of the same engine for Rust's proptest
([proptest-rs/proptest#658](https://github.com/proptest-rs/proptest/pull/658)).
As far as we know it is the first choice-sequence shrinker in the
OCaml ecosystem.
[QCheck2](https://www.tweag.io/blog/2021-07-21-qcheck2-integrated-shrinking/)
and [Bam](https://discuss.ocaml.org/t/ann-bam-a-property-based-testing-with-internal-shrinking/14661)
use Hedgehog-style [integrated shrinking over lazy rose
trees](https://www.well-typed.com/blog/2019/05/integrated-shrinking/)
(Bam's design notes on shrinking are
[here](https://francoisthire.github.io/bam/bam/shrinking.html));
base_quickcheck's `Shrinker.t` for scalars is
[literally `atomic`](https://github.com/janestreet/base_quickcheck/blob/v0.17.0/src/shrinker.ml#L44),
meaning failing ints, floats, chars, and bools are reported exactly as
generated. A longer comparison of the three shrinking models, and why
binds are where they differ, is in
[blog/draft-choice-tapes.md](blog/draft-choice-tapes.md).

**This repo is a proof of concept built to be upstreamed.** The Wave 1
end state is a small set of tape hooks in the real `splittable_random`,
defaulting to no-ops, after which the vendored copies are unnecessary
for the unchanged-generator integration. Wave 2 separately tests which
generator-aware annotations and representations are worth proposing to
`base_quickcheck`. The results table, call-site-compatible runner, and
preserved Wave 1 proof exist to make those proposals small and
well-evidenced rather than a leap of faith.

## Write-up

[**Brief for the paper's authors and Jane Street reviewers**](AUTHOR-BRIEF.md)
is the shortest technical tour: what is working, what would need to merge
upstream, the current evidence, and the limits which remain.

[**What Tapecheck currently covers from _Property-Based Testing in
Practice_**](PAPER-CAPABILITIES.md) is the outreach claim boundary. It maps
all seven research opportunities to current entry points, executable evidence,
and explicit limitations. In short: RO5 and the textual core of RO6 are the
strongest results; RO4 is useful but incomplete; RO2, RO3, and RO7 are
prototypes rather than the automation the paper proposes.

[**Evidence manifest**](EVIDENCE.md) maps the quantitative claims to runnable
tests, preserved raw output, and a pinned public companion-repository commit.
It also identifies the evidence which is still historical or not yet ready to
cite externally.

[**Porting Hypothesis's shrinker to OCaml, and measuring what it
cost**](docs/porting-conjecture-to-ocaml.md) is the longer research narrative.
It includes the cross-language [Shrinking
Challenge](https://github.com/jlink/shrinking-challenge) (Hypothesis 9/9,
Tapecheck 4/9 under the documented protocol) and diagnoses each loss. Some
tables combine preserved experiment revisions, so use the capability matrix
and `ROADMAP.md`, not the essay alone, for current product status.

## Results

### Fast-randomness integration

The published *Fail Faster* artifact makes generator throughput an adoption
constraint rather than an afterthought. Tapecheck itself does not require C.
The artifact's AllegrOCaml implementation offers an optional C implementation
of the Splittable-random algorithm for faster generation: its ordinary staged
backend enters Tapecheck's `splittable_random` seam, while that optional path
bypasses ordinary OCaml sampling calls.

The ordinary inactive seam has its own direct measurement. A same-body study
first exposed and motivated removal of an avoidable wrapper. In a separately
predeclared 60-pair confirmation after that optimisation, Boolean,
bounded-integer, and float primitive-loop point estimates were 0.9930, 1.0063,
and 1.0190, with familywise-95% upper bounds no higher than 1.0255. This passes
the predeclared 5% rule on one host and OCaml 5.3.0; it is not a zero-cost or
end-to-end throughput claim.

Tapecheck now exposes an active backend path (`Intercept.run_*`) and a one-time
activity test (`Intercept.is_active`). Controlled measurements reject calling
the OCaml dispatcher around every C primitive: two predeclared batches found
roughly 1.14×, 1.22×, and 1.61× primitive-call ratios. Selecting a complete
direct or observed loop once instead met the predeclared ±2% equivalence margin
for Boolean, integer, and float loops in both primary and confirmation batches.

Those are current-toolchain microbenchmarks, not AllegrOCaml or end-to-end
property-test timings. A local AllegrOCaml patch now retains direct and
observed generated bodies and selects once per generated value; its selection
and 100-seed Boolean smoke test passes under BER MetaOCaml 4.14.1. A real
v0.16 seam backport also passes primitive and split/perturb smoke tests, and
the dual test observes exactly one callback per active Boolean value. The
first actual dual-generated integer-list timing found a ratio of 0.9898 with a
paired 90% interval of 0.9750–1.0022, which did not establish equivalence. A
predeclared 24-block replication then covered scalar Boolean, Boolean-list,
nested-list, and integer-list workloads. Boolean and integer-list familywise
intervals fit within ±2%; list and nested-list uncertainty extended outside
the margin, so the rule requiring every workload to pass still rejects blanket
equivalence. All 192 observations and matching pairwise checksums are retained.
The source audit, patches, raw observations, and exact claim boundary are linked
from [EVIDENCE.md](EVIDENCE.md) and
[design/fail-faster-integration.md](design/fail-faster-integration.md).

### Current production structural lists

The opt-in Wave 2 `Generator.list_structural` now has a predeclared, per-seed
comparison against current ordinary lists. Both arms use the same tape engine,
100 fixed seeds, size 10, at most 200 generated cases, and a 5,000-attempt
shrink budget:

| Property | Ordinary exact | Structural exact | Ordinary calls | Structural calls |
|---|---:|---:|---:|---:|
| Length at least 3 | 100/100 | 100/100 | 151.21 | 41.55 |
| Sum at least 100 | 100/100 | 100/100 | 94.52 | 25.58 |
| Head equals length | 47/100 | 99/100 | 134.01 | 13.13 |

For seeds where both arms found a failure, structural lists reduced mean shrink
calls by 72.52%, 72.94%, and 90.36% respectively. The ordinary-arm positive
control matches all 300 corresponding observations in the current headline
harness. Full individual observations, checked analyses, and the frozen design
are pinned through [EVIDENCE.md](EVIDENCE.md). The
[full current matrix](CURRENT-COMPARISON.md) puts Base stock, final-Wave-1/current
ordinary Tapecheck, structural Tapecheck, and Hypothesis beside one another
without pretending their call-count boundaries are identical.

This is an arm-level generator-plus-shrinker result, not a pure shrink-pass
effect: structural lists use interleaved continuation choices and give each
element the ambient size, so the two arms need not generate the same original.
That representation is an opt-in production API rather than the default
because size-dependent recursive generators still need migration to an
explicit leaf budget.

### Historical unchanged-generator table

The table below is a historical Wave 1 comparison generated at commit
`13fbd09`; it predates both the final Wave 1 checkpoint (`695082c`) and the
later Wave 2 generator and span work. Subsequent Wave 1 engine changes altered
the mean call counts, so these must not be presented as final-Wave-1 costs.
The exact-minimum rates did survive, and a per-seed rerun at `695082c` is
byte-for-byte identical to current Wave 2 on these eight subjects. See
[EVIDENCE.md](EVIDENCE.md) for the revision-pinned records.

Eight properties, 100 seeds each. **One generation phase per seed:** the
tape engine finds the failure, and the *same* original value it found is
handed to base_quickcheck's own greedy shrink loop, exactly as
`Test.run` performs it. Full output:
[design/shrink-table-results.txt](design/shrink-table-results.txt).

| property (each links to its definition) | stock minimal | tape minimal | stock calls | tape calls |
|---|---|---|---|---|
| [int uniform, fail iff >= 123457](demo/shrink_table.ml#L157) | 0/100 | 100/100 | 0 | 34 |
| [pair, fail iff a + b >= 100](demo/shrink_table.ml#L165) | 0/100 | 100/100 | 0 | 18 |
| [list, fail iff length >= 3](demo/shrink_table.ml#L172) | 0/100 | 100/100 | 6 | 147 |
| [list, fail iff sum >= 100](demo/shrink_table.ml#L179) | 0/100 | 100/100 | 4 | 90 |
| [filtered evens, fail iff >= 100](demo/shrink_table.ml#L186) | 0/100 | 100/100 | 0 | 79 |
| [bind: length-prefixed list, sum >= 100](demo/shrink_table.ml#L230) | 0/100 | 100/100 | 0 | 52 |
| [zig-zag, fails iff \|m-n\| = 1](demo/shrink_table.ml#L204) | 11/100 | 83/100 | 0 | 34 |
| [self_len, fails iff hd l = length l](demo/shrink_table.ml#L221) | 46/100 | 47/100 | 3 | 130 |

**Two things this table does not say, and should not be read as
saying.**

First, on the scalar rows the stock column is `0/100` at a cost of *zero
test calls*, and that is not a shrinker being beaten — it is a shrinker
that never runs. `Base_quickcheck.Shrinker.int` is `atomic`, i.e.
`fun _ -> Sequence.empty`, as are `bool`, `char`, `int32`, `int63` and
`int64`. base_quickcheck deliberately shrinks structure rather than
scalars. So `0/100` on those rows is definitional, not measured. The
rows where the stock shrinker genuinely does work and still reaches
`0/100` are the two list rows (6 and 4 calls) and, more interestingly,
`self_len`, where it reaches **46/100 against the tape engine's 47/100** —
essentially a tie.

Second, the comparison used to be worse than uncontrolled: until
2026-08-01 the stock arm ran its own untaped generation schedule, on the
assumption that it matched the engine's. It stopped matching once the
engine gained edge-case-biased generation and the correlated-value
mutation, and by then the two schedules produced *completely* different
originals — measured 100 differing out of 100, on every property, zero
overlap (`diag2/probe_identical.ml`). The table was comparing generators
as well as reducers. It no longer does.

## Usage

`Tape_test` exposes the same five callable entry points as
`Base_quickcheck.Test` (plus the same `Config` and `(module S)` shape), so
ordinary property calls switch by replacing the module name. This is
source-level compatibility, not identical semantics: the
`quickcheck_shrinker` your types already declare is accepted and ignored.
Likewise, `with_sample` and `with_sample_exn` delegate to base_quickcheck and
preserve its stock sample sequence. They are useful sampling utilities, but do
**not** satisfy Base's promise to preview the values that this module's `run`
would see: Tapecheck's three test-running entry points use their own taped,
edge-biased generation schedule.

```ocaml
Tape_test.run_exn
  ~f:(fun t -> ...your property...)
  ~regressions:"my_test.regressions"   (* optional *)
  (module My_type)
```

`?regressions` persists each shrunk failure as a serialised case containing
both the ambient `size` and the recorded tape image. It replays persisted
cases before random generation on later runs, reproducing the failing value
independently of RNG seeds and robustly across sampling-distribution changes,
provided the generator's replay control flow remains compatible. The image
alone is not a complete reproducer: changing `size` can change the decoded
value. Corrupt entries fail loudly rather than silently passing.

`?realign` (default `` `Both ``) controls how shrink replay handles a
kind mismatch, which arises when an edit changes the shape of a
generator (flipping a tag that selects a differently shaped branch).
Two policies exist and neither dominates: `` `Consume `` skips the
stale entry and resyncs, `` `Freeze `` holds it for a later same-kind
draw. `` `Both `` replays a misaligned proposal under both and keeps
the shortlex-better result: never worse than either, free on
proposals that stay aligned (the common case), and a modest extra cost
only on the misaligned minority. It reaches the canonical simplest
example more often on shape-changing (`bind`/union) generators. See
[design/realign-bench-results.txt](design/realign-bench-results.txt).

`?report` (default `` `Summary ``) controls what every call prints to
stdout: one line giving cases tried, valid, discarded and failing, plus
any health-check warnings. Pass `` `Silent `` to turn it off. Worth
knowing before you wire tapecheck into a large suite — the default is
per *call*, so a 47-property suite prints 47 lines:

```ocaml
Tape_test.run_exn ~report:`Silent ~f:(fun t -> ...) (module My_type)
```

To inspect those counts programmatically, pass an accumulator created with
`Tape_test.Stats.create` through `?stats`, then call
`Tape_test.Stats.snapshot`. Accumulators may be reused across calls and are
cumulative; each snapshot is an immutable copy, including a deterministically
sorted event table. The mutable engine representation is not part of this API.

`Tape_engine.run` is the lower-level entry point; `?domains:n`
evaluates generation cases and shrink proposals in parallel (worker
pool). Accepted-edit sequences and results are identical to the
sequential engine (lowest-index acceptance); with a pool the engine
evaluates batches speculatively, so attempt COUNTS can exceed the
sequential run's. Your generator and test function must be safe to
call from multiple domains: in particular, recursive generators built
on `Generator.fixed_point`/`recursive_union` memoize through OCaml's
`Lazy`, which is not concurrency-safe, and a race surfaces as a raised
exception (never a hang or corruption; the engine re-raises worker
exceptions on the calling domain). On a rare-failure workload with a
~100us test body the pool is a 6.3x wall-clock win at 8 domains and
11.9x at 16 — but only while the run is dominated by GENERATION. When
shrinking dominates it is a net **loss**: 0.86x at 8 domains and 0.70x
at 32, because speculative batch evaluation raises the attempt count
(582 sequential to 1618 at 32 domains) without shortening the critical
path. `bench_domains/` measures all three cases; the preserved
[raw output and provenance](bench_domains/results/README.md) come from one
machine whose hardware metadata was not recorded, so these figures demonstrate
the workload dependence rather than a portable speedup estimate. A single
"parallel speedup" number for this engine would be a choice of workload rather
than a property of the pool.

## How the interception works

Every `base_quickcheck` generator draws from one sequential
`Splittable_random.t`, and every primitive carries its constraints
(`int ~lo ~hi`, `float ~lo ~hi`, `bool`). This workspace provides a
`splittable_random` library with the identical public interface that
delegates to the real implementation but records draws as typed tape
choices when a tape is attached to the state. The vendored
`base_quickcheck` compiles against the shim. At the Wave 1 checkpoint
(`695082c`) that interception was the entire generator integration;
current Wave 2 also adds explicit structural capabilities to the
vendored generator layer. Details and design history:
[design/choice-tape-for-base-quickcheck.md](design/choice-tape-for-base-quickcheck.md).

`Generator.fn` splits the random state. Split-off streams used to be
untaped, so generated functions did not shrink at all; stream-keyed
tapes fixed that, and `test_bq/test_fn_shrink.ml` pins it — `fn/point`
reaches `f(0)=100`, `fn/sum` reaches `f(1)+f(2)=100`,
and no orphan seed shrinks to a stuck result (the test asserts
that, plus that more than 15 of the 40 seeds find a failure at all; the
run behind this paragraph found 40 of 40).

## Edge-case-biased generation

Shrinking finds a small failing example, but it can only shrink an
example the generator actually produced; uniform sampling essentially
never generates the values that trigger the bugs worth shrinking
towards in the first place — an exact bound, zero, or (famously,
[proptest-rs/proptest#500](https://github.com/proptest-rs/proptest/issues/500))
one number being an exact multiple of another. This is a direct port
of [Python Hypothesis](https://hypothesis.readthedocs.io/)'s
Conjecture provider
([`draw_integer`/`draw_float`](https://github.com/HypothesisWorks/hypothesis/blob/master/hypothesis-python/src/hypothesis/internal/conjecture/providers.py)):
a fresh draw (nothing recorded on the tape yet to replay) rolls a
biased distribution instead of a plain uniform one — a boundary
candidate (the range's ends, one step in from each, the shrink target)
roughly 1 time in 16, at *any* range width, plus a magnitude drawn from
a weighted random bit-size of the shrink target on wide integer
ranges, and a filtered pool of "weird" floats (±0, ±1, simple
fractions, the bounds, one ulp inside each bound) about 1 time in 20.
The exact shape is adapted from the sibling Rust port's
`TestRunner::sample_integer_biased`/`maybe_weird_float`
([proptest-rs/proptest](https://github.com/proptest-rs/proptest),
`test_runner/runner.rs`), itself a port of the same Hypothesis design,
for how to express it over fixed-width `int64`/`float` choices rather
than Python's arbitrary-precision integers. Only fresh draws are
biased; a value already on the tape replays untouched, so shrinking is
unaffected in kind.

Measured on the `proptest` divisibility property above (`total_count`
in `[0, 1_000_000]`, `count` in `[1, 100_000]`, bug iff `total_count
mod count = 0`): plain uniform sampling hits it in **26 of 200,000**
draws (0.013%); with this bias, **10,070 of 200,000** (5.0%) — about
387x. Run end-to-end through `Tape_engine.run` over 100 seeds, the
engine now finds *and* fully shrinks the bug to its true minimal
witness `(0, 1)` on every seed (was 2/100 before this port — the other
98 seeds never even saw a failing case in 200 tries). Over the full
`int64` range, plain uniform sampling produced `Int64.min_value` 0
times in 200,000 draws; biased generation produces it directly on the
very first generated case. The original development run also reported a
roughly 24ns incremental integer-draw cost, but that timing is not a current
performance claim: the harness uses one wall-clock invocation and its absolute
result has drifted with the implementation and host. The deterministic hit and
minimisation counts above still reproduce with
`dune exec bench_edgecase/edgecase_bench.exe`; use the predeclared experiments
linked from EVIDENCE.md for performance conclusions.

## Building and installing the preview

Tapecheck is installable today as an explicit three-pin preview. The patched
`splittable_random` must sit underneath a recompiled `base_quickcheck`, so the
preview deliberately supplies replacement packages for both dependencies as
well as the `tapecheck` package. This is not yet the desired single-package
installation; upstream
[splittable_random#2](https://github.com/janestreet/splittable_random/pull/2)
is the open discussion about removing the replacement pins. Its submitted v1 seam
is not sufficient for the current engine: split children remain hook-free,
while generated-function replay requires keyed observer propagation. A
corrected v2 direction is documented in
[design/upstream-pr-splittable-random.md](design/upstream-pr-splittable-random.md).

To exercise the exact installation path in a disposable OCaml 5.3 switch:

```sh
opam switch create tapecheck-preview 5.3.0
./scripts/test_opam_install.sh tapecheck-preview
```

The script installs the local `splittable_random`, `base_quickcheck`, and
`tapecheck` pins in dependency order, then builds an external consumer. The
consumer compiles an ordinary `[@@deriving quickcheck]` generator through the
installed PPX, runs the installed `Tape_test` facade through its
`Base_quickcheck.Test.S`-compatible module type, and checks that installed
`Tape_engine` shrinks to the exact boundary `50`. The script modifies the
named switch, which is why the recipe uses a disposable one.

For development in the source workspace, install the dependencies of all
three local packages and run the full suite:

```sh
opam switch create 5.3.0
opam install . --deps-only --with-test
dune runtest --force
```

The workspace build continues to use its vendored copies directly; see
Vendoring. The three-pin preview is an adoption and packaging check, not a
claim that users should replace Jane Street packages permanently.

Building and testing need the 5.3.0 switch created above: on a switch
missing `stdio`/`ppx_sexp_conv` and the other ppx deps, most test
directories fail to build and dune silently runs only what remains.
Also, plain `dune test`/`dune runtest` can exit 0 without re-running
anything, because dune caches test actions and replays a cached success
instead of re-executing. The reliable way to actually run the suite is

```
dune runtest --force
```

and each test executable prints a success line naming itself (e.g.
`test_tape: all passed`), so a partial run cannot be mistaken for a
full-suite green.

The engine also builds and runs under OxCaml, bit-identically:

```
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
dune build --profile oxcaml
```

(The ppx-deriving pieces are gated off under the oxcaml profile; the
OxCaml ppxlib fork has a divergent parsetree. `ox_demo/` contains the
benchmarks and the mode-checker demonstration described in the blog
posts under `blog/`.)

## Vendoring and licenses

Why vendor at all? Because OCaml links statically at compile time:
the opam-installed base_quickcheck is sealed against the opam
splittable_random (module references are resolved when it is built,
with interface digests), and there is no LD_PRELOAD equivalent to
swap a library underneath it. For base_quickcheck to draw through the
tape shim it must be recompiled against the shim, and a dune
workspace with vendored sources is the only way to arrange that
without touching your opam switch. The Wave 1 checkpoint doubles as
the proof of the unchanged-generator claim: its vendored copies are
pinned release sources plus the short, reviewed interception and
portability patches. Current Wave 2 has additional generator changes,
all retained in `vendor/patches/`. (Two paths
make the copies unnecessary later: an `opam pin` of a patched
splittable_random, which would rebuild the whole switch against the
shim, or upstreaming the tape hooks, a dozen functions defaulting to
no-ops.)

This repo is MIT (LICENSE.md). `vendor/` contains Jane Street code,
also MIT. `vendor/upstream.lock` pins both the release tag and peeled
Git commit: base_quickcheck v0.17.1 at `f8035fdf...` and
splittable_random v0.17.0 at `0f4a6ef5...`. Their LICENSE.md is kept
with each copied component:

- `vendor/base_quickcheck`: Wave 1 changed only the dune file (dropping
  `public_name`) and one portability fix in `generator.ml`
  (deduplication via `Set.Using_comparator` instead of a `Comparator`
  record field, for Base v0.17/v0.18 compatibility). Current Wave 2 also
  adds span annotations to ordinary list elements and the opt-in
  `list_structural`, `recursive_with_max_leaves`, and
  `with_reorderable_span` generator APIs.
- `vendor/sr_real`: `splittable_random`'s implementation, module
  renamed, with the interception seam and split/perturb hook propagation,
  a small Base v0.17/v0.18 compat block, and upstream's inline test/bench
  blocks stripped (they use APIs that drifted in v0.18 previews; originals
  are recoverable by reversing the declared patch).
- `vendor/splittable_random`: OUR shim, implementing the upstream
  public interface over `sr_real` plus the tape hooks.
- `vendor/ppx_quickcheck{,_expander,_runtime}`: unmodified except dune
  files (names, workspace-local runtime deps, oxcaml profile gate).

The source provenance is executable rather than documentary:

```
./scripts/check_vendor_provenance.sh
./scripts/refresh_vendor.sh
./scripts/sync_consumer_snapshot.sh --check
```

The check fetches each pinned tag, rejects a changed tag-to-commit mapping,
applies the declared patches to a temporary checkout, and byte-compares every
upstream-derived vendored `.ml`, `.mli`, and licence. The locally authored
`vendor/splittable_random` shim is covered by normal tests and snapshot checks,
not by upstream provenance. The refresh command regenerates the canonical
upstream-derived copies and then the package-shaped Core consumer; it does not
copy dune/opam packaging templates. CI runs both check-only paths.

## Status

Early but real: the engine, the call-site-compatible wrapper, persistence, and
the parallel pool all work and are tested; the shrink-quality table above is a
preserved historical Wave 1 result. A checked three-pin opam preview is
installable, but the clean single-package release still depends on the
upstream observer seam. Compatibility does not mean identical
`Base_quickcheck.Test` semantics; see Usage and Building above. The current
[roadmap](ROADMAP.md) and findings in `design/` distinguish publication work
from the known shrink-quality frontier. The goal is upstreaming (see above); if
you are a base_quickcheck or splittable_random maintainer reading
this, the interesting files are `vendor/splittable_random/` (the
hooks, a dozen functions) and `design/choice-tape-for-base-quickcheck.md`
(the findings your generators surfaced).

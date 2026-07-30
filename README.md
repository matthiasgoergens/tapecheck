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
input to your own generator. And because the tape is recorded
underneath the generator, your existing generators, including
everything `[@@deriving quickcheck]` produces, participate with
**zero changes**.

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

**This repo is a proof of concept built to be upstreamed.** The
honest end state is a dozen tape hooks in the real splittable_random,
defaulting to no-ops, at which point every copy under `vendor/`
disappears and base_quickcheck gains integrated shrinking as an
opt-in engine. Everything here (the results table, the drop-in
wrapper, the vendored-unmodified proof) exists to make that a small,
well-evidenced proposal rather than a leap of faith.

## Results

Six properties, 100 seeds each, identical failing examples handed to
both shrinkers ("stock" is base_quickcheck's own greedy loop, exactly
as `Test.run` performs it). Full output:
[design/shrink-table-results.txt](design/shrink-table-results.txt).

| property (each links to its definition) | stock minimal | tape minimal | tape avg calls |
|---|---|---|---|
| [int uniform, fail iff >= 123457](demo/shrink_table.ml#L114) | 0/100 | 100/100 | 38 |
| [pair, fail iff a + b >= 100](demo/shrink_table.ml#L121) | 0/100 | 100/100 | 22 |
| [list, fail iff length >= 3](demo/shrink_table.ml#L128) | 0/100 | 100/100 | 641 |
| [list, fail iff sum >= 100](demo/shrink_table.ml#L135) | 0/100 | 100/100 | 98 → 456 |
| [filtered evens, fail iff >= 100](demo/shrink_table.ml#L142) | 0/100 | 100/100 | 90 |
| [bind: length-prefixed list, sum >= 100](demo/shrink_table.ml#L149) | 0/100 | 100/100 | 59 |

The `100/100` fully-minimal column is unchanged by the edge-case-biased
generation added since the numbers above were first measured (see
`outreach/` and `tape/tape.ml`): every property still shrinks to its
exact global minimum on every seed, on a fresh re-run. The average
call counts shifted because biased generation finds a *different*
first failing example per seed, and by how much splits cleanly along
one line: the scalar-int rows (int uniform, pair, filtered evens) draw
one or two `int_uniform_inclusive` values directly and landed within
noise of their old figure (38, 22, 91→90); the three that draw a
`base_quickcheck` list (list-length, list-sum, and the bind row's
`list_with_length`) rose noticeably (466→641, 98→456, 49→59) because
list length and per-element size budgeting go through
`vendor/sr_real/sr_real.ml`'s `Log_uniform.int`, which itself makes
*two* nested calls back into the same `int64` intercept our bias
sits behind (one to pick a bit-count, one to sample uniformly within
that bit-band) — so a single list draw touches many more biased
integer choices than a single scalar draw does, and each one now has
a 1-in-16 chance of landing on a boundary value instead of a plain
uniform sample. More of the tape's early choices start away from
their shrink target, so there is genuinely more to shrink, not a
regression in what shrinking finds.

The bind row deserves elaboration, because it is where the models
genuinely differ. The generator draws a length first and then a list
that depends on it, a monadic bind:

```ocaml
let gen =
  let%bind len = Generator.int_uniform_inclusive 1 64 in
  Generator.list_with_length (Generator.int_uniform_inclusive 0 1000) ~length:len
```

The property fails whenever the list sums to at least 100, so the
ideal counterexample is the one-element list `[100]`. For a
`Shrinker.t` this generator is a dead end: shrinkers are derived from
type structure, and an ad-hoc bind like this has no derivable
shrinker at all, so `Test.run` reports whatever 64-element monster was
generated. Even a hand-written list shrinker could not safely help,
since it cannot know that the list's length was itself a generated
value with its own constraints. The tape engine does not have the
problem: the length is just the first recorded choice, so the engine
lowers it while deleting one element's choices, replays the generator
(which rebuilds a consistent, shorter list by construction), and
repeats until nothing can be removed without the sum dropping below
100, arriving at exactly `[100]`.

## Usage

`Tape_test` mirrors `Base_quickcheck.Test` (same `Config`, same
`(module S)`, same `run`/`run_exn`/`result`); existing suites switch
by replacing the module name. The `quickcheck_shrinker` your types
already declare is accepted and ignored.

```ocaml
Tape_test.run_exn
  ~f:(fun t -> ...your property...)
  ~regressions:"my_test.regressions"   (* optional *)
  (module My_type)
```

`?regressions` persists each shrunk failure as a serialized tape and
replays persisted tapes before random generation on later runs: exact
reproduction of the failing value, independent of RNG seeds, robust
to distribution changes. Corrupt entries fail loudly rather than
silently passing.

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
~100us test body the pool is a 4.6x wall-clock win at 8-16 domains.

## How the interception works

Every base_quickcheck generator draws from one sequential
`Splittable_random.t`, and every primitive carries its constraints
(`int ~lo ~hi`, `float ~lo ~hi`, `bool`). This workspace provides a
`splittable_random` library with the identical public interface that
delegates to the real implementation but records draws as typed tape
choices when a tape is attached to the state. The vendored
base_quickcheck compiles against the shim unmodified; that is the
entire integration. Details and design history:
[design/choice-tape-for-base-quickcheck.md](design/choice-tape-for-base-quickcheck.md).

Known limitation: `Generator.fn` splits the random state; split-off
streams are untaped, so generated functions do not shrink (Hypothesis
has the same limitation).

## Edge-case-biased generation

Shrinking finds a small failing example, but it can only shrink an
example the generator actually produced; uniform sampling essentially
never generates the values that trigger the bugs worth shrinking
towards in the first place — an exact bound, zero, or (famously,
[proptest-rs/proptest#500](https://github.com/proptest-rs/proptest/issues/500))
one number being an exact multiple of another. This is a direct port
of [Python Hypothesis](https://hypothesis.readthedocs.io/)'s
Conjecture provider
([`draw_integer`/`draw_float`](outreach/hypothesis-sources/providers_hypothesis.py)):
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
very first generated case. The bias itself costs roughly 24ns per
integer draw on top of the ~110ns a recording tape already costs (vs.
~10-13ns with no tape at all). Reproduce with
`dune exec bench_edgecase/edgecase_bench.exe`.

## Building

```
opam switch create 5.3.0
opam install dune base stdio ppx_jane
dune test
```

(No opam install of splittable_random or base_quickcheck is needed or
used: the workspace's vendored copies shadow them; see Vendoring.)

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
without touching your opam switch. It doubles as the proof of the
zero-changes claim: the vendored copies are pristine release
tarballs, and the short list of exceptions is right here. (Two paths
make the copies unnecessary later: an `opam pin` of a patched
splittable_random, which would rebuild the whole switch against the
shim, or upstreaming the tape hooks, a dozen functions defaulting to
no-ops.)

This repo is MIT (LICENSE.md). `vendor/` contains Jane Street code,
also MIT, vendored from the v0.17 opam release tarballs with a
LICENSE.md in each directory:

- `vendor/base_quickcheck`: unmodified except the dune file (dropped
  `public_name`) and one portability fix in `generator.ml`
  (deduplication via `Set.Using_comparator` instead of a `Comparator`
  record field, for Base v0.17/v0.18 compatibility).
- `vendor/sr_real`: `splittable_random`'s implementation, module
  renamed, with a small Base v0.17/v0.18 compat block and upstream's
  inline test/bench blocks stripped (they use APIs that drifted in
  v0.18 previews; originals in the release tarball).
- `vendor/splittable_random`: OUR shim, implementing the upstream
  public interface over `sr_real` plus the tape hooks.
- `vendor/ppx_quickcheck{,_expander,_runtime}`: unmodified except dune
  files (names, workspace-local runtime deps, oxcaml profile gate).

## Status

Early but real: the engine, the drop-in wrapper, persistence, and the
parallel pool all work and are tested; the shrink-quality table above
is reproducible with `dune exec demo/shrink_table.exe`. Roadmap and
findings live in `design/`. The goal is upstreaming (see above); if
you are a base_quickcheck or splittable_random maintainer reading
this, the interesting files are `vendor/splittable_random/` (the
hooks, a dozen functions) and `design/choice-tape-for-base-quickcheck.md`
(the findings your generators surfaced).

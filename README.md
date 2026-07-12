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
| [list, fail iff length >= 3](demo/shrink_table.ml#L128) | 0/100 | 100/100 | 466 |
| [list, fail iff sum >= 100](demo/shrink_table.ml#L135) | 0/100 | 100/100 | 98 |
| [filtered evens, fail iff >= 100](demo/shrink_table.ml#L142) | 0/100 | 100/100 | 91 |
| [bind: length-prefixed list, sum >= 100](demo/shrink_table.ml#L149) | 0/100 | 100/100 | 49 |

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

`Tape_engine.run` is the lower-level entry point; `?domains:n`
evaluates generation cases and shrink proposals in parallel (worker
pool; results are deterministic and identical to the sequential
engine). On a rare-failure workload with a ~100us test body this is a
4.6x wall-clock win at 8-16 domains.

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

## Building

```
opam switch create 5.3.0
opam install dune base stdio splittable_random base_quickcheck ppx_jane
dune test
```

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

# A choice-tape shrink engine for base_quickcheck

Goal: give every existing base_quickcheck generator Hypothesis-quality
integrated shrinking without changing a single generator, by porting the
Conjecture choice-tape model (record generation decisions, shrink by
editing the tape and replaying generation). Prior art: our proptest port
(proptest-rs/proptest#658), whose architecture this reuses; the tape
passes and their measured value are documented there.

## Why OCaml, why base_quickcheck

As of mid-2026 no OCaml PBT library uses choice-sequence shrinking. The
integrated-shrinking line (QCheck2, Bam) settled on Hedgehog-style lazy
rose trees, which compose through map/filter but degrade at monadic
bind. base_quickcheck has no integrated shrinking at all: Shrinker.t is
a manual value-to-smaller-values function, derived structurally by
[@@deriving quickcheck], with the classic invariant-violation and
bind-blindness problems. A tape engine strictly dominates both models
at bind, and base_quickcheck's architecture makes the port unusually
clean, for two reasons measured from its source (v0.17):

1. One sequential random state. Generator.generate threads a single
   Splittable_random.t through the whole generation.
   Splittable_random.split is called in exactly one place
   (Generator.fn, for random functions); everything else is strictly
   sequential, which is the shape a tape needs.
2. Typed draws with constraints at the seam. The Splittable_random
   primitives are bool, int ~lo ~hi (and int32/int63/int64/nativeint),
   float ~lo ~hi, unit_float. Unlike proptest's RngCore byte seam,
   every draw arrives with its bounds attached, so the tape records
   typed, bounded choices without any strategy migration at all. What
   took proptest a per-strategy migration is free here.

## Architecture

Three libraries in one dune workspace:

- `tape`: the engine core, no dependency on base_quickcheck. Choice
  type (Integer of {value; lo; hi} in int64 offset space, Float of
  {value; lo; hi}, Bool), recording/replaying state, shortlex
  comparison, serialization, and the shrink pass schedule ported from
  the proptest engine: all-to-target, span deletion with exponential
  batching, redistribute pairs, minimize duplicates, lower-and-delete
  (the length-prefix pass), per-choice minimization with exponential
  probing. Spans mark generator call boundaries.
- `splittable_random` (shim): implements the exact public interface of
  Jane Street's splittable_random, delegating to the real
  implementation underneath, but consulting a thread-local (later:
  explicitly threaded) tape when one is active. dune workspace
  resolution makes the vendored, UNMODIFIED base_quickcheck compile
  against this shim instead of the upstream library; that is the whole
  interception trick.
- `engine`: the runner. generate-record-test loop, shrink loop
  (edit tape, replay through Generator.generate, accept iff still
  failing and shortlex-smaller), failure persistence, and a
  Base_quickcheck.Test.run-compatible entry point so existing test
  suites opt in by changing one function name (or eventually nothing).

`split` handling: the shim gives split-off states a fresh untaped
stream (recorded as a single Split marker for alignment). Generated
functions therefore do not shrink; Hypothesis has the same limitation.
`perturb` likewise records a marker. Both are rare in practice.

## MVP milestones

1. Tape core: choices, recorder, replayer, shortlex order. Unit tests.
2. Shim compiles and records; vendored base_quickcheck builds against
   it; a hand-written generator records and replays byte-identically.
3. Shrink loop with the trivial pass and per-choice minimization;
   demonstrate on int/filter/bind examples that stock Shrinker.t
   cannot shrink (bind-generated data, filtered domains).
4. Span passes (deletion, lower-and-delete) wired to list/string
   generators (base_quickcheck generates lists via a size draw then
   elements: the length-prefix shape our lower-and-delete pass was
   built for).
5. The demo: a shrink-quality table like the proptest PR #658 comment,
   base_quickcheck Shrinker vs tape, same properties, 100 seeds.
6. OxCaml showcase (after the OCaml core works): build under 5.2.0+ox;
   parallel shrink attempts via the Parallel API with modes proving
   data-race freedom; benchmark generation with unboxed floats.

## Presentation

The pitch to Jane Street mirrors the proptest one: no generator
changes, measured shrink-quality tables, and a small diff surface (the
shim implements their own published interface). Options, in increasing
order of ambition: external library on opam; PR adding the tape hooks
to splittable_random proper (a dozen primitives); tape engine as an
alternative Test.run in base_quickcheck itself.

## Non-goals for now

- Observer/fn shrinking (split limitation above).
- Replacing Shrinker.t: it keeps working; the engine simply does not
  need it.
- Sizes: base_quickcheck's ~size parameter is orthogonal (it caps
  recursion); the tape records whatever draws happen under any size.

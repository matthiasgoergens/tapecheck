# Upstream `splittable_random` seam

Current status, checked against the public repository on 2026-08-20:
[`janestreet/splittable_random#2`](https://github.com/janestreet/splittable_random/pull/2)
is open. The submitted branch is `tape-hooks-v017`, rebased onto upstream
master. The last maintainer response, on 2026-08-13, said it remained on the
back burner rather than rejecting it.

This document supersedes the pre-submission draft formerly kept here. It
separates what PR #2 actually contains from what the current Tapecheck engine
has since proved necessary.

## What the submitted PR contains

The public diff adds an optional interceptor field to each random state and
hooks `int64`, `float`, `unit_float`, and `bool`. It notifies `on_split` and
`on_perturb`, but states produced by `split`, `split_into_capsule`, and capsule
copying are hook-free. The interceptor is a public record, and each ordinary
draw branches on its optional presence.

That was enough for the first flat-stream engine, but it is not the interface
the current product uses.

## Corrections to the public claim boundary

The PR description and the 2026-07-16 comment cite an alternating
minimum-of-five microbenchmark as evidence of no measurable unused cost. That
design was later withdrawn. Two separately predeclared, randomised,
fresh-process batches do not reproduce one stable Boolean or bounded-integer
conclusion. The honest result is unresolved unused-seam cost on one host, not
equivalence and not a measured regression of a specific size.

The description also says the seam covers every existing generator. The draw
hooks observe flat generators, but the submitted split contract is insufficient
for generated functions: `Base_quickcheck.Generator.fn` draws the function body
from split and perturbed child states. A hook-free child cannot record or replay
those draws. Tapecheck's tested function support instead uses `on_split : unit
-> observer option` and `on_perturb : int -> observer option`, so each child is
attached to its own keyed tape stream.

`with_intercept` returns a snapshot record copy in the submitted implementation;
the interface comment saying it shares the underlying PRNG should also be
corrected.

## What the current local seam adds

The current `Sr_real.Intercept` prototype has four layers:

1. bounded primitive record/replay hooks;
2. observer propagation across `split` and `perturb`, including the salt;
3. weighted Boolean and structural-span notifications used by opt-in Wave 2
   generators; and
4. backend-facing `run_*` functions plus `is_active`, for randomness
   implementations which are pointwise equivalent but bypass ordinary
   `Splittable_random` calls.

All four layers are useful, but submitting them as one growing public record
would repeat the compatibility problem already identified in the local
interface documentation. The structural layer is also a Base Quickcheck design
decision, not a prerequisite for reviewing flat choice recording.

## Performance result from the *Fail Faster* boundary

The public AllegrOCaml artifact has an ordinary staged backend which calls
`Splittable_random`, and a faster C drop-in backend which mutates the same state
while bypassing those functions. Local pointwise controls confirm both backends
produce the same primitive sequence.

Calling OCaml `run_*` dispatch around every C primitive is rejected: in two
predeclared batches, direct-dispatch ratios remained roughly 1.14 for Boolean,
1.22 for bounded integer, and 1.61 for float loops. Testing `is_active` once
and choosing a complete direct or observed loop met a predeclared ±2%
equivalence margin for every loop in both primary and confirmation batches.

This supports a whole-generated-body split, not the current per-draw upstream
field by itself. Actual dual AllegrOCaml code generation and artifact-level
throughput remain unmeasured.

## Recommended upstream sequence

Do not silently expand PR #2 to the complete experimental record.

1. Correct the stale performance and coverage claims in the existing thread.
2. Ask whether maintainers prefer the current PR to remain a design discussion
   or be replaced by a narrower Wave 1 v2.
3. If they want code, make the Wave 1 observer abstract rather than exposing a
   record whose required fields cannot evolve. It must propagate keyed
   observers through split and perturb, and its documentation must say snapshot
   copy rather than shared state. The vendored prototype now implements this
   shape: `Intercept.create` has optional delegating callbacks and `t` is
   abstract at the interface. A minimal, locally checked delta against the
   exact public PR head is retained in
   `proposals/splittable_random-pr2-v2.patch`, with its verification boundary
   in `proposals/SPLITTABLE-RANDOM-PR2-V2.md`.
4. Keep weighted choices and spans in a separate Base Quickcheck-facing
   proposal, after the primitive seam direction is accepted.
5. Treat accelerated backends separately: expose one activity query and select
   complete generated bodies once. Do not put an OCaml callback around every
   fast primitive.
6. Before claiming inactive-path acceptability, measure complete ordinary and
   staged generators—not only primitive loops—on Jane Street-relevant hardware.

The current vendored seam remains a workable product path if Jane Street does
not want this machinery in the core random state. Packaging then needs an
explicit pinned replacement stack rather than pretending Tapecheck can be a
normal package over unmodified `splittable_random`.

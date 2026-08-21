# Upstream `splittable_random` seam

Current status, checked against the public repository on 2026-08-21:
[`janestreet/splittable_random#2`](https://github.com/janestreet/splittable_random/pull/2)
is open. The submitted branch is `tape-hooks-v017`, rebased onto upstream
master and updated to the tested propagation contract at `e50930a`. The last
maintainer response, on 2026-08-13, said it remained on the back burner rather
than rejecting it.

This document supersedes the pre-submission draft formerly kept here. It
separates what PR #2 actually contains from what the current Tapecheck engine
has since proved necessary.

## What the submitted PR contains

The public diff adds an optional interceptor field to each random state and
hooks `int64`, `float`, `unit_float`, and `bool`. `Intercept.t` is abstract and
constructed with optional delegating callbacks. Ordinary `split` installs the
interceptor returned by `on_split`; `perturb` passes its salt and may install a
replacement. Capsule states remain hook-free because ordinary closures cannot
cross capsule boundaries. Each ordinary draw branches on the interceptor's
optional presence.

## Corrections to the public claim boundary

An early comment cited an alternating minimum-of-five microbenchmark as
evidence of no measurable unused cost. A
stronger same-body study found a real cost and exposed an avoidable wrapper on
the inactive path. After removing that wrapper, a separately predeclared
60-pair confirmation bounded the inactive cost below 5% for Boolean,
bounded-integer, and float primitive loops on one host and OCaml 5.3.0. Point
estimates were -0.7%, +0.6%, and +1.9%; the largest familywise-95% upper bound
was 2.6%. The honest claim is this measured single-host bound, not zero cost or
general end-to-end equivalence.

The public description and comment now state that narrower performance claim.
The updated diff also uses the tested generated-function contract: `on_split :
unit -> observer option` and `on_perturb : int -> observer option`, so split and
perturbed states can attach to keyed tape streams. Its `with_intercept`
documentation correctly describes a snapshot record copy rather than shared
state.

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

The public AllegrOCaml artifact—not Tapecheck itself—has an ordinary staged
backend which calls `Splittable_random`, and an optional faster C drop-in
implementation of the same random algorithm. The C path mutates the same state
while bypassing the OCaml functions where Tapecheck observes draws. Local
pointwise controls confirm both backends produce the same primitive sequence.

Calling OCaml `run_*` dispatch around every C primitive is rejected: in two
predeclared batches, direct-dispatch ratios remained roughly 1.14 for Boolean,
1.22 for bounded integer, and 1.61 for float loops. Testing `is_active` once
and choosing a complete direct or observed loop met a predeclared ±2%
equivalence margin for every loop in both primary and confirmation batches.

This supports a whole-generated-body split, not the per-draw upstream field by
itself. The dual AllegrOCaml path now compiles and passes behavioural controls.
In a four-workload replication, Boolean and integer-list intervals met the
predeclared ±2% margin while Boolean-list and nested-list intervals did not.
Blanket equivalence and end-to-end artifact throughput therefore remain open.

## Upstream sequence

The first three preparation steps are complete: the stale claims were
corrected, the abstract v2 contract was tested, and the existing PR was updated
in place. The retained delta in `proposals/splittable_random-pr2-v2.patch` and
its verification record in `proposals/SPLITTABLE-RANDOM-PR2-V2.md` preserve the
transition from the original head.

The remaining scope boundaries are unchanged:

1. Keep weighted choices and spans in a separate Base Quickcheck-facing
   proposal, after the primitive interception direction is accepted.
2. Treat accelerated backends separately: expose one activity query and select
   complete generated bodies once. Do not put an OCaml callback around every
   fast primitive.
3. Before making a broad inactive-path claim, measure complete ordinary and
   staged generators—not only primitive loops—on Jane Street-relevant hardware.

The current vendored seam remains a workable product path if Jane Street does
not want this machinery in the core random state. Packaging then needs an
explicit pinned replacement stack rather than pretending Tapecheck can be a
normal package over unmodified `splittable_random`.

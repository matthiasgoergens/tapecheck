# Integrating Tapecheck with *Fail Faster*

Status: Current integration design and checked proposal

Tapecheck revisions: backend dispatch `ed84dc8`; one-time activity test
`1633249`

External source revisions: `vee-effekt/ff_artifact` at `225a142` and
`alpha-convert/waffle-house` at `69d843f`

Last verified: 2026-08-20

The OOPSLA 2026 [*Fail Faster* artifact][artifact] makes the performance
question concrete. Its AllegrOCaml implementation stages
`base_quickcheck`-shaped generators and offers several randomness backends.
Tapecheck must preserve that work rather than asking an adopter to choose
between integrated shrinking and fast generation.

[artifact]: https://github.com/vee-effekt/ff_artifact
[allegro]: https://github.com/alpha-convert/waffle-house

## Compatibility audit

The artifact's `Random_intf.S` is the relevant boundary. Its ordinary
`Sr_random` backend emits calls to `Splittable_random.bool`, `int`, `float`,
and `Log_uniform.int`. Those calls already enter Tapecheck's interception seam;
staging itself is not a blocker.

The fastest pointwise-equivalent backend, `C_sr_dropin_random`, instead emits
calls to C functions which mutate the seed inside the same
`Splittable_random.State.t`. That preserves the random stream but bypasses the
OCaml sampling functions where Tapecheck used to dispatch hooks. A state could
therefore carry a live tape observer while fast generated draws remained
invisible. Merely adding Tapecheck to AllegrOCaml's link dependencies would be
an incorrect integration.

The independent-state `C_random` backend has a different issue: it copies the
Splittable-random state into its own representation. It cannot inherit an
observer attached to the original state without an explicit hook-bearing
adapter. It is not covered by the current proposal.

## Backend-facing dispatch

Tapecheck's patched `Splittable_random.Intercept` now exports `run_bool`,
`run_int`, `run_int64`, `run_float`, and `run_unit_float`. An optimized backend
passes its pointwise-equivalent primitive as `~default`:

```ocaml
Splittable_random.Intercept.run_int state ~lo ~hi
  ~default:(fun state ~lo ~hi -> Fast_runtime.int state lo hi)
```

With no observer, the implementation performs one hook-presence branch and
calls the fast default without integer boxing or conversion. With Tapecheck
attached, it records or replays the bounded choice and calls the supplied
primitive only when new randomness is required. Integer adaptation to
Tapecheck's `int64` choice representation occurs only on the active path.

The regression in `test_bq/test_roundtrip.ml` checks all three AllegrOCaml
primitive shapes. It proves direct delegation when hook-free, records Boolean,
integer, and float draws through backend dispatch, and replays them under a
different backend implementation without calling that implementation.

The first checked AllegrOCaml patch changed the frozen C drop-in backend to use
this API for ordinary, unchecked, and log-uniform integer draws plus Boolean
and float draws. It remains preserved as
[`proposals/rejected/allegr_ocaml-per-draw-dispatch.patch`](../proposals/rejected/allegr_ocaml-per-draw-dispatch.patch)
and in the companion evidence. It is no longer the recommended integration.

Two separately predeclared fresh-process batches measured this per-draw design
around the same pointwise-equivalent C primitives. Dispatch/direct-C ratios
were approximately 1.14 for Boolean, 1.22 for bounded integer, and 1.61 for
float draws in both batches. Every confirmation 95% interval lay above 1.02.
These are primitive-call ratios, not complete-generator slowdowns, but they
rule out negligible per-draw dispatch on that build.

`Intercept.is_active` now supplies the next architectural boundary. Generated
code can select a direct fast generator once when it is false and an observed
generator using `run_*` when it is true. The inactive path then pays one
decision per generated value rather than one OCaml dispatch per primitive.

That boundary has also been measured in two separately predeclared batches.
Around three-million-draw direct/observed loops, every primary and confirmation
90% selected/direct-C interval lay inside 0.98–1.02; point estimates remained
within about 0.4% of one. This establishes local equivalence for the one-time
selection harness.

A local patch now adds that code-generation path. Each staged backend can
produce one complete compiled `size`/`random` function, and `jit_dual` combines
a `C_sr_dropin_random` function with an `Sr_random` function. Generated code
tests `Intercept.is_active` once at the `Base_quickcheck.Generator.create`
boundary. Existing generator descriptions must be instantiated once per
backend, but individual combinators are unchanged. The patch and verification
record are in
[`proposals/ALLEGR-OCAML-DUAL-OBSERVER.md`](../proposals/ALLEGR-OCAML-DUAL-OBSERVER.md).

The patch compiles and its isolated smoke test passes under BER MetaOCaml
4.14.1. Distinct constant bodies prove both branch directions; direct-C and
ordinary-SR Boolean bodies agree on 100 paired seeds. The frozen toolchain
resolves `splittable_random` v0.16, so a second patch backports delegating
primitive observers, active-state detection, snapshot attachment, and
split/perturb propagation. Its isolated seam test passes, and the combined
dual test observes exactly one Boolean callback per active generated value.

## Dual-generated timing

The first actual AllegrOCaml timing was predeclared before calibration. It uses
the staged `list int` combinator at size 50, excludes JIT and warm-up from the
timed interval, pins each fresh process to one logical CPU, and retains 20
randomised paired blocks. Each process generates 3,000,000 values; every paired
checksum matches.

Dual inactive / existing direct C has geometric-mean ratio 0.9898, paired 90%
bootstrap interval 0.9750–1.0022, and paired median 0.9950. The interval crosses
the predeclared 0.98–1.02 margin, so this result **does not establish
equivalence**. One retained block has ratio 0.8598; the plan forbade timing
outlier exclusion.

As a secondary control, dual active with a delegating observer / unobserved
ordinary SR has ratio 1.0684 (90% interval 1.0591–1.0794). This includes
observer delegation on every primitive; it is not Tapecheck recording-mode or
complete property-test throughput. Raw observations and the checked analysis
are in the companion evidence under
`experiments/fail-faster-dual-performance/2026-08-20-69d843f`.

## What remains unproven

The timings now cover the rejected per-draw design, a local whole-generator
selection harness, and one actual dual-generated AllegrOCaml workload. The
dual source and real v0.16 seam build and pass isolated smoke tests under BER
MetaOCaml 4.14.1. They have not been compiled in the artifact's 25 GB Docker
environment, tested on its complete benchmark suite, or replicated on a second
machine.

A publication-grade adoption experiment should therefore:

1. apply both checked patches to the frozen artifact and run its differential
   tests to extend pointwise equality beyond the isolated Boolean control;
2. compare active recording and complete bug-finding throughput separately,
   and replicate inactive generation across representative workloads;
3. retain the artifact commit, patch, toolchain, raw observations, affinity,
   load, and compiler configuration; and
4. repeat important timing conclusions on a second machine before making an
   adoption-wide claim.

Until that experiment exists, the defensible statement is: **Tapecheck can
observe AllegrOCaml's pointwise-equivalent backend; measured per-draw OCaml
dispatch is too expensive, while a one-time whole-generator activity decision
meets the ±2% equivalence criterion in two local batches. The dual-generated
implementation compiles and passes an isolated smoke test in the pinned BER
toolchain; the real v0.16 seam also passes isolated behavioural controls, while
the first staged inactive timing fails to establish the predeclared ±2%
equivalence claim and end-to-end performance remains open.**

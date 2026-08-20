# Whole-generator fast-path selection: predeclared measurement design

This experiment asks whether selecting a direct C generator body once through
`Splittable_random.Intercept.is_active` has practically negligible cost when no
observer is attached.

The primary estimand is the geometric paired ratio `selected time / direct C
time`, separately for Boolean, bounded-integer, and float loops. A fresh
benchmark process is the experimental unit. Both arms run the same C primitive
and identical loop; the selected arm performs one activity test before choosing
the complete direct or observed loop. The state is passed through
`Sys.opaque_identity` so the compiler cannot prove the answer from its
construction site.

Before inspecting timings, the design is fixed as follows:

- 12 successful processes, run sequentially on logical CPU 31;
- 10 paired, counterbalanced blocks per draw kind and process;
- 3,000,000 draws per timed arm and 250,000 untimed warm-up draws per arm and
  draw kind;
- a monotonic `Mtime_clock` counter, with state construction and a full major
  collection outside the timed region;
- Dune's `release` profile plus executable and C-stub `-O3` flags;
- rotating draw-kind order, with five selected-first and five direct-first
  blocks for every draw kind in every process;
- no exclusion of timing observations;
- accumulator equality for every warm-up and timed pair; and
- process-cluster bootstrap intervals using 50,000 resamples and seed
  `20260820`.

The primary analysis and sensitivity check match the fast-backend dispatch
experiment. Selection is considered practically equivalent for a draw kind
only when the complete 90% interval lies inside the predeclared 0.98–1.02 ratio
margin.

The C backend and pointwise positive control are identical to the preceding
experiment. This benchmark does not use BER MetaOCaml, attach a tape, measure
the active observed body, or time a complete property test. It isolates the
one-time inactive selection boundary on this compiler, binary, and host. A
fresh confirmation batch is required before treating a result as stable here;
cross-machine generalisation requires a second host.

# Fast-backend inactive dispatch: predeclared measurement design

This experiment asks whether routing an artifact-style C randomness backend
through `Splittable_random.Intercept.run_*` measurably slows draws when no
observer is attached.

The primary estimand is the geometric paired ratio `dispatch time / direct C
time`, separately for Boolean, bounded-integer, and float draws. A fresh
benchmark process is the experimental unit. The two arms call the same C
primitive in the same binary and begin from identical random states; the
dispatch arm adds the backend-facing interception entry point.

Before inspecting timings, the design is fixed as follows:

- 12 successful processes, run sequentially on logical CPU 31;
- 10 paired, counterbalanced blocks per draw kind and process;
- 3,000,000 draws per timed arm and 250,000 untimed warm-up draws per arm and
  draw kind;
- a monotonic `Mtime_clock` counter, with state construction and a full major
  collection outside the timed region;
- Dune's `release` profile plus the executable and C stub `-O3` flags, so the
  backend-facing dispatch is not hidden behind development-profile opacity;
- rotating draw-kind order, with five dispatch-first and five direct-first
  blocks for every draw kind in every process;
- no exclusion of timing observations;
- accumulator equality for every warm-up and timed pair; and
- process-cluster bootstrap intervals using 50,000 resamples and seed
  `20260820`.

The analysis averages log paired ratios within each process and then across
processes. It reports geometric means and percentile 90% and 95% bootstrap
intervals. Inactive dispatch is considered practically equivalent for a draw
kind only when its complete 90% interval lies inside the predeclared 0.98–1.02
ratio margin. A process-level median analysis is retained as a sensitivity
check.

The C sampler independently implements the same SplitMix draw algorithms used
by the current vendored `splittable_random` and accesses the first two fields of
its runtime state, matching the published *Fail Faster* C drop-in technique.
This unsafe representation access is deliberate and confined to the
benchmark. Exact accumulator equality is a necessary positive control, not a
general statistical test of the PRNG.

This benchmark does not use BER MetaOCaml, measure generated-code staging,
attach a tape, or time complete property tests. Even an equivalence result
would support only the inactive backend dispatch on this compiler, binary, and
host. Important timing conclusions require a fresh confirmation batch and a
second machine before generalisation.

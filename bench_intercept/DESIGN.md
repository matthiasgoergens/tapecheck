# Unused interception seam: predeclared measurement design

This experiment asks whether adding Tapecheck's interception seam measurably
slows a `Splittable_random` draw when interception is not active.

The primary estimand is the geometric paired ratio
`seam time / no-hook time`, separately for Boolean, bounded-integer and float
draws. The fresh benchmark process is the experimental unit. Measurements
within a process reduce noise but are not treated as independent replicates.

Before inspecting results, the design is fixed as follows:

- 12 successful processes, run sequentially on one pinned logical CPU;
- 10 paired, counterbalanced blocks per draw kind and process;
- 3,000,000 draws per timed arm and 250,000 untimed warm-up draws per arm and
  draw kind;
- a monotonic `Mtime_clock` counter, with generator construction and a full
  major collection outside the timed region;
- rotating draw-kind order, with five seam-first and five no-hook-first blocks
  for each draw kind in every process;
- no exclusion of timing observations;
- accumulator equality as a positive control for behavioural parity; and
- process-cluster bootstrap intervals using 50,000 resamples and seed
  `20260820`.

The primary analysis averages log paired ratios within each process and then
across processes. It reports geometric means and percentile 90% and 95%
process-cluster bootstrap intervals. The seam is considered practically
equivalent on this workload only when the complete 90% interval lies inside
the predeclared 0.98–1.02 ratio margin. A process-level median analysis is
reported as a sensitivity check.

The machine, compiler, source commit, affinity and raw observations are
retained with the result. The run script refuses a dirty tracked worktree and
an existing result directory.

This is deliberately a narrow microbenchmark. It neither measures an active
interceptor nor establishes end-to-end Tapecheck, Hypothesis, or Allegro
performance. In particular it does not test the staging and fast-randomness
claims in *Fail Faster*.

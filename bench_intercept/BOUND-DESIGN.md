# Inactive interception seam: predeclared upper-bound study

## Question and estimand

The primary question is whether the production inactive observer check adds
more than 5% to primitive draw time on this host.  The primary estimand is the
geometric paired ratio `seam/direct` for Boolean, bounded-integer, and float
draws.  Here `direct` calls the same compiled production default function as
`seam`; the only semantic difference in the measured loop is the inactive
observer check.

The practical decision rule is non-inferiority, not a claim that the cost is
zero.  The seam passes for a draw kind when its one-sided, familywise-95%
bootstrap upper confidence bound is at most 1.05.  It passes the study only if
all three draw kinds pass.  The familywise bounds use Bonferroni-adjusted
98.333rd percentiles.

## Experimental design

- 40 independent paired invocations per draw kind and contrast;
- 10,000,000 draws per timed invocation and 500,000 untimed warm-up draws;
- each arm runs in a fresh process pinned to logical CPU 31, an E-core without
  an SMT sibling on this Intel Core i9-13900K;
- arm order is exactly counterbalanced within each draw kind and contrast;
- pair order rotates across draw kinds and contrasts to spread temporal drift;
- both arms use the same seed within a pair, and unequal accumulators abort the
  run;
- elapsed time is measured inside the process with `Mtime_clock`, excluding
  startup, warm-up, state construction, and a full major collection;
- `perf stat` simultaneously retains user-space instructions, cycles,
  branches, and branch misses as mechanistic secondary measurements;
- no timing or counter observation is excluded;
- 100,000 paired-block bootstrap resamples use seed `20260821`.

Two predeclared secondary contrasts accompany the primary isolated contrast:

1. `seam/nohook` compares the two complete compiled modules used by the earlier
   experiment.  It tests external validity but remains susceptible to module
   code-layout effects.
2. `active/seam` installs a delegating observer.  Its callback dispatch is a
   positive control.  The timing harness is considered sensitive only if the
   familywise-95% lower bound exceeds 1.02 for all three draw kinds.

The analysis also reports ordinary paired 90% and 95% intervals, process-level
median sensitivity estimates, and counter ratios.  Those are descriptive and
do not replace the primary rule.

## Scope

This is a single-host primitive-throughput study.  Passing supports the claim
that the inactive production check costs less than 5% for these three hot
loops on this host and toolchain.  It does not establish zero cost, active
Tapecheck throughput, end-to-end property-test performance, or portability to
other machines and compilers.

The design and harness must be committed before the result directory is
created.  The run script refuses tracked changes and an existing result
directory.

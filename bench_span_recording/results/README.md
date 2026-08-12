# Attached span-recording benchmark

This benchmark measures a different cost from `bench_spans`: both treatments
use a tape-attached generator and record identical random choices. The control
replaces the existing Base list element-span callbacks with no-ops, while the
treatment uses the production tape callbacks. Observational spans are not
retained; this therefore measures the attached no-record fast path, not the
cost of a future full structural trace.

The experimental unit is one paired block. Each block runs the same seeded
cases in both treatments, in one of 60 balanced randomly shuffled orders after
warm-up. The primary estimand is the geometric mean ratio of process CPU
nanoseconds per generated element, with a 95% Student-t interval over paired
log ratios. Processor frequency, thermal state, GC state, binary layout, and
treatment order are expected nuisances. No blocks are excluded. A +5%
slowdown was declared practically material before running the benchmark.

Two fixed-length workloads are used: length 30 is representative of ordinary
size-bounded generation, while length 1,000 is a sensitivity case for the
`Tape.finish` sort. The latter is not evidence about typical user workloads.
Each result is machine-local and must be replicated on fresh processes and
upstream hardware before generalising.

The two retained length-30 processes from the initial binary estimated -0.59%
(95% interval -1.17% to +0.00%) and +0.12% (-0.34% to +0.58%). Its
length-1,000 sensitivity process estimated -0.20% (-1.25% to +0.87%). After a
label-only source edit and rebuild, the `final` length-30 process estimated
-4.19% (-4.70% to -3.68%); it is not a same-binary replication of the first
two. All exclude a +5% callback-body slowdown on this machine. The large and
inconsistent negative direction is not plausibly a real optimisation and may
reflect binary layout or changing machine state; do not claim a speed-up.

Both arms attach the interceptor and therefore both pay `with_span` dispatch,
two callback calls, and `Exn.protect`. The estimand is deliberately the
production callback body versus no-op callback bodies, which tests the
retention/filtering change but not the already-merged seam against a seam-free
build.

Commands:

```sh
nice -n 10 ionice -c 2 -n 7 taskset --cpu-list 31 \
  _build/default/bench_span_recording/bench_span_recording.exe \
  --length 30 --samples 3000

nice -n 10 ionice -c 2 -n 7 taskset --cpu-list 31 \
  _build/default/bench_span_recording/bench_span_recording.exe \
  --length 1000 --samples 100
```

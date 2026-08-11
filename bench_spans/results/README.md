# Span benchmark results

These are raw outputs from the 2026-08-11 adversarial replications of the
unattached `with_span` benchmark.  Each file contains all 60 paired-block
observations; none were excluded.

Command:

```sh
nice -n 10 ionice -c 2 -n 7 taskset --cpu-list 31 \
  _build/default/bench_spans/bench_spans.exe
```

Environment: Linux 7.1.6 on a 13th Gen Intel Core i9-13900K, logical CPU 31,
OCaml 5.3.0, Dune 3.24.0, native build with `-O3`.  The four estimated paired
effects were -0.46%, -0.39%, -0.80%, and -0.68%.  Their two-sided 95%
intervals are in the corresponding files.

Three earlier process-CPU runs are reported in `WAVE2-CONTINUATION-LISTS.md`,
but their raw observations were not retained.  That omission is recorded
rather than reconstructed from rounded aggregates.

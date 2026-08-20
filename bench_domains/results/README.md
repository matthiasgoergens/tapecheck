# Domain-pool benchmark, 2026-08-09

`2026-08-09.txt` is the raw output behind the parallelism discussion in the
top-level README. The measured harness was introduced by Tapecheck commit
`dc90c1b`; its current source remains in `bench_domains/`.

The run used OCaml 5.3.0 and reported `recommended_domain_count = 32`, but the
original record did not preserve CPU, affinity, scheduler, compiler flags,
runtime/GC configuration, or system load. Treat the exact timings as a
historical single-machine observation. The robust conclusion is qualitative:
generation-heavy workloads benefited from parallel evaluation on that machine,
whereas shrink-heavy work became slower as speculation increased the number of
attempts.

Re-run from a compatible Tapecheck checkout with:

```sh
opam exec --switch=5.3.0 -- dune exec bench_domains/bench_domains.exe
```

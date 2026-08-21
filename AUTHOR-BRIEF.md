# Tapecheck: an OCaml answer to internal shrinking

Tapecheck is a working choice-sequence engine for `base_quickcheck`, motivated
by the research opportunities in Goldstein, Cutler, Dickstein, Pierce, and
Head, *Property-Based Testing in Practice* (ICSE 2024). It ports the central
Conjecture idea from Python Hypothesis: record typed, bounded generator choices
and shrink that recording by replaying the generator.

The strongest answer is to RO5. A shrink candidate is input to the original
generator rather than a value edited after generation, so accepted examples
are reconstructed through the generator's own invariants. Tapecheck also
implements the textual core of RO6—visible valid/discarded/failing counts,
events, timings, shrink work, and health checks—and useful but incomplete RO4
features such as edge-biased draws and opt-in structural generators.

This is installable as a checked three-pin opam preview: matching replacement
pins for `splittable_random` and `base_quickcheck`, followed by `tapecheck`.
The clean end state remains an ordinary `tapecheck` package after the small
random-observer seam is upstream.

## Two separable upstream stages

Wave 1 is already a useful adoption proposal with no changes to existing
generator implementations. Wave 2 is the optional next step: small,
generator-aware changes buy further improvements on structural data.

### Wave 1: unchanged generators

Wave 1 records beneath the generator layer through no-op-by-default hooks in
`splittable_random`. Existing `base_quickcheck` generator implementations,
derived generators, and ordinary property call sites do not need structural
rewrites. `Tape_test` supplies the five ordinary `Base_quickcheck.Test` entry
points with documented semantic differences.

The final Wave 1 checkpoint is `695082c`. A package-shaped consumer rebuilds
`core` and `core_kernel` against the patched stack in a fresh switch, runs
seven existing Core-dependent properties, and proves interception with an
atomic positive control which must shrink exactly to `123457`.

The remaining packaging blocker is the clean single-package route, not a
missing engine or an untested installer. `scripts/test_opam_install.sh`
installs the three preview pins in a disposable switch and builds an external
consumer which uses the installed Base Quickcheck PPX, runs the installed
`Tape_test` facade, and checks an exact lower-level engine shrink. Until the
recording seam exists upstream, that explicit replacement stack is necessary.

### Wave 2: generator cooperation

Some Hypothesis shrink quality depends on structural information unavailable
in a flat sequence of PRNG draws. Wave 2 adds opt-in structural spans,
continuation-encoded lists, reorderable or descendable children, discarded
attempts, and an explicit recursive leaf budget.

The production `Generator.list_structural` comparison was predeclared and
retains every individual observation:

| Property | Ordinary exact | Structural exact | Ordinary calls | Structural calls |
|---|---:|---:|---:|---:|
| Length at least 3 | 100/100 | 100/100 | 151.21 | 41.55 |
| Sum at least 100 | 100/100 | 100/100 | 94.52 | 25.58 |
| Head equals length | 47/100 | 99/100 | 134.01 | 13.13 |

On paired seeds which found a failure in both arms, structural lists used
72.52%, 72.94%, and 90.36% fewer shrink calls respectively. The generators do
not share the same original value, so this is a complete-arm result rather
than a pure shrink-pass effect.

Structural lists should be proposed as an addition first, not made the default
silently: each element receives the ambient size, while some existing
`fixed_point` programmes rely on ordinary lists splitting that size to
terminate. Recursive users need migration to an explicit leaf budget.

## Current comparison with Hypothesis

`CURRENT-COMPARISON.md` is generated from per-seed evidence for eight selected
properties. Ordinary Tapecheck reaches the same exact-minimum rate as
Hypothesis on the six original common properties. On independently generated
schedules it reaches 83/100 exact zig-zag failures against Hypothesis's 67/100,
while structural lists reach 99/100 on head-equals-length against 53/100.

Those are selected quality results, not proof that Tapecheck is generally
better. Hypothesis controls its own generation schedule, and its property-call
counts include generation plus shrinking while Tapecheck reports shrinking
only. The matrix keeps those boundaries visible rather than turning them into
a misleading speed ratio.

## Known frontier

The regression suite deliberately preserves counterevidence:

- 5/8 exact minima in the ported Hypothesis shrink-quality cases;
- 21/48 exact one-element poisoned-container minima;
- 161/200 optima in a small exhaustive oracle; and
- 235 certificates where a smaller reachable failing tape remains after the
  engine settles.

RO2 bisimulation and RO3 state-machine helpers exist, but not the zero-setup
automation or full scenario tooling proposed by the paper. RO7 targeting is a
lower-level prototype. There is no claim of blanket feature or performance
parity with Hypothesis.

## A plausible upstream discussion

The existing `splittable_random` PR #2 is an early Wave 1 seam, not the current
interface. Its public no-measurable-cost claim predates the controlled
replacement experiment, and its hook-free split children do not support the
now-tested generated-function path. A corrective status comment is drafted in
`proposals/COMMENT-splittable_random-2.md` for approval before author outreach.

1. Review a corrected minimal `splittable_random` recording seam independently
   of the shrink policy and later structural experiments.
2. Decide whether an opt-in Tapecheck runner belongs in `base_quickcheck`, a
   companion package, or an experimental Jane Street namespace.
3. Evaluate `list_structural` and `recursive_with_max_leaves` as opt-in
   generator additions with their migration caveats documented.
4. Keep changes to default generators for a later compatibility decision,
   supported by the retained quality, distribution, and cost evidence.

The newer [*Fail Faster*](https://arxiv.org/abs/2503.19797) results make
generator throughput a first-class adoption constraint. Two separately
predeclared unused-seam batches are retained in the companion evidence, but
their Boolean and bounded-integer conclusions do not replicate across batches.
That instability rules out a negligible-overhead claim from this one-host
microbenchmark. The published AllegrOCaml source also exposed a concrete
integration issue: its C drop-in backend bypasses ordinary
`Splittable_random` calls. Tapecheck now provides backend-facing `run_*`
dispatch with record/replay controls. Two fresh-process batches show that
calling it on every fast primitive is materially too expensive, so that first
checked AllegrOCaml patch is retained as a rejected design. The seam now also
exposes `is_active`, enabling generated code to select a direct fast body once
when untaped and an observed body only when Tapecheck is active. Two further
predeclared batches put that one-time selection within the ±2% equivalence
margin for all three local primitive loops. A local AllegrOCaml implementation
now compiles under BER MetaOCaml 4.14.1 and passes branch-selection plus
100-seed paired-Boolean smoke tests. A real v0.16 seam backport passes its
primitive and split/perturb smoke tests, and the combined dual test observes
one callback per active generated Boolean. A serious upstream evaluation must
still measure recording mode and complete staged generators with raw
observations. The first 20-block integer-list timing did not establish the
predeclared ±2% inactive equivalence claim. A further predeclared replication
retained 192 observations across Boolean, Boolean-list, nested-list, and
integer-list workloads. Boolean and integer-list familywise intervals fit the
margin; the two other intervals did not, so the honest conclusion remains no
blanket equivalence claim. Point estimates ranged from 0.9955 to 1.0114.

The capability-by-capability mapping is in `PAPER-CAPABILITIES.md`; claim
provenance is in `EVIDENCE.md`; the longer engineering roadmap is in
`ROADMAP.md`.

## Reproduction gates

```sh
opam exec --switch=5.3.0 -- dune runtest --force
bash scripts/check_api_surface.sh
bash scripts/check_consumer_snapshot.sh
UV_CACHE_DIR=/tmp/tapecheck-uv-cache uv run python scripts/check_markdown_links.py
```

The fresh Core-dependent consumer recipe and expected positive-control output
are in `docs/testing-core-dependent-code.md`.

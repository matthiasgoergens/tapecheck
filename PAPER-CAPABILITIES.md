# ICSE 2024 capability matrix

This document maps the seven research opportunities in Goldstein, Cutler,
Dickstein, Pierce, and Head, *Property-Based Testing in Practice* (ICSE 2024),
to Tapecheck's current executable surface. It is a claim boundary for outreach:
“implemented” below means a normal or explicitly named Tapecheck entry point is
covered by a checked-in test; “partial” names what is still missing.

The strongest story is RO5 and RO6, with useful pieces of RO4. RO2, RO3, and
RO7 have prototypes rather than the automation the paper asks for. RO1 is a
research question, not something a library can claim to have solved.

## Matrix

| Paper opportunity | Current status | What Tapecheck demonstrates | Important limit | Executable evidence |
|---|---|---|---|---|
| **RO1: understand time constraints** | Partial engineering support | Case counts, shrink-attempt limits, an optional whole-shrink time limit, and separate generation/test/shrink timing | No per-example deadline, phase controls, or user study of acceptable budgets. Existing wall-clock measurements are machine-local and historical | `test_stats_accounting`, `test_pool_leak`; `SHRINK-BUDGET-DESIGN.md` |
| **RO2: differential/model-based testing** | Partial | `Bisim.Make` drives the same state-dependent command sequence through reference and candidate implementations, compares returns and exceptions, and diagnoses operations which agree only by raising | The specification and module adapters are handwritten; this is not the paper's proposed zero-setup module comparison | `test_bisim_health`, `test_bisim_adversarial`, `bisim_demo/queue_bisim.ml` |
| **RO3: make more scenarios high-leverage** | Partial | `Stateful.Make` generates commands from the current model state; `Bundle` references remain coherent when earlier producer commands shrink away | No memory snapshots, environment mocking, temporal-logic interface, rule discovery, or complete Hypothesis state-machine surface | `test_stateful` |
| **RO4: well-distributed, precondition-satisfying generators** | Partial, useful today | Existing `[@@deriving quickcheck]` generators run unchanged; `assume` records invalid cases; fresh integer/float draws inject boundary and special values; opt-in structural lists and recursive leaf budgets improve shrinkability; a lower-level targeted search can maximise an objective | `assume` is rejection, not constraint solving. Structural generators are not yet safe defaults. `run_target` is not integrated with `Tape_test`, has no test-body `target`, labels, multiple objectives, or Pareto corpus | `test_bq/test_wrapper`, `test_bq/test_structural_generators`, `demo/structural_table.ml`, `test_target`, `bench_edgecase`; `WAVE2-PRODUCTION-GENERATORS.md` |
| **RO5: improve shrinking interfaces** | Implemented core; explanation partial | Choice-sequence shrinking replays the generator, so every accepted counterexample is regenerated through the original construction path. It handles binds, filters, generated functions, structural spans, persistence, resumption, and exposes bounded free-variation analysis of a minimal example | Exact shrink quality still trails Hypothesis on documented subjects. Explanation perturbs input choices but does not attribute source lines or offer interactive control over shrink steps | `test_bq/test_shrink`, `test_bq/test_fn_shrink`, `test_bq/test_explain`, `test_regression`, `test_shrink_quality`, `test_poison_lists`; `HYPOTHESIS-GAPS.md` |
| **RO6: evaluate testing effectiveness** | Implemented textual core | Passing runs announce valid, discarded, and failing counts by default. `event` aggregates user labels; full reports include timing and shrink work; health checks detect excessive filtering, slow generation, routinely large data, large base examples, and trivial observations | No graphical distribution browser, coverage integration, or JSONL observability stream. Some checks are OCaml analogues rather than byte-for-byte Hypothesis ports; pooled health accounting remains limited | `test_bq/test_stats`, `test_stats_accounting`, `test_stats_api`, `test_trivial_only`, `demo/stats_demo.ml` |
| **RO7: connect evaluation to generator improvement** | Prototype only | `Tape_engine.run_target` reuses tape mutations to hill-climb a numeric objective | No bar-chart/editor workflow, branch-directed feedback, automatic generator rewriting, normal-run integration, or labelled multi-objective targeting | `test_target`; `TARGET-PBT.md` |

## Integration evidence

The package-shaped workspace in `bonsai-tapecheck-hunt/` is the most relevant
Jane Street integration check. In a fresh OCaml 5.3 switch it pins the patched
`splittable_random` and `base_quickcheck` packages, rebuilds `core` and
`core_kernel` against them, and then runs:

- seven passing properties over two `core`-dependent libraries copied from
  Bonsai; and
- a positive control whose Base Quickcheck shrinker is atomic, which must find
  `value >= 123457` and shrink it exactly to `123457`.

The latter prevents a link-only success from being mistaken for working tape
interception. See `docs/testing-core-dependent-code.md` for the fresh-switch
recipe and expected output.

A smaller installation control now exercises the user-facing boundary. In a
disposable OCaml 5.3 switch, `scripts/test_opam_install.sh SWITCH` installs the
three local preview pins and builds `install-smoke/` as a separate Dune
project. That consumer compiles an unchanged `[@@deriving quickcheck]` type
through the installed PPX, runs the installed `Tape_test` facade through its
`Base_quickcheck.Test.S`-compatible module type, and requires installed
`Tape_engine` to shrink an integer exactly to `50`. The three pins are still a
migration mechanism; they do not remove the reason to upstream the observer
seam.

## Shrink-quality and performance claim boundary

Tapecheck has strong selected results, not blanket Hypothesis parity. The
checked-in quality guards deliberately preserve counterexamples to overclaiming:

- the ported exact-minimum suite currently reaches 5/8 targets;
- poisoned containers reach 21/48 one-element minima, against Hypothesis's
  48/48;
- the exhaustive small oracle records 161/200 global optima; and
- the pairwise witness test retains 235 certificates of a smaller reachable
  failing tape after the engine settled.

These are active research targets. The README's older eight-property table is
useful evidence that tape shrinking helps selected unchanged generators, but it
is not a current cross-framework benchmark. In particular, scalar Base
Quickcheck shrinkers in several rows are atomic.

Performance claims must likewise stay narrow. The tape adds per-draw recording
cost, and parallel shrinking is currently a net loss on the measured workloads.
Attempt counts are reproducible algorithmic cost; historical nanosecond and
wall-clock figures remain machine-local. The current generated matrix is
deliberately an algorithmic quality-and-call-count comparison, not a timing
benchmark.

The authors' later [*Fail Faster: Staging and Fast Randomness for
High-Performance PBT*](https://arxiv.org/abs/2503.19797) makes the upstream
performance bar more concrete: it reports large generator-throughput gains
from staging and a faster randomness source while preserving generator
semantics pointwise. The published AllegrOCaml artifact's ordinary staged
backend already enters Tapecheck through `Splittable_random`; its faster C
drop-in backend bypasses those functions. Backend-facing `Intercept.run_*`
dispatch closes the behavioural wiring gap, but two separately predeclared
batches show that paying it per primitive is materially slower than direct C
on this build. The first checked source patch is therefore rejected.

`Intercept.is_active` enables a whole-generator direct/observed split. That
boundary met a ±2% equivalence criterion in two primitive-loop batches, and a
local AllegrOCaml dual-code patch plus real v0.16 observer backport now compile
and pass behavioural controls under BER MetaOCaml 4.14.1. The first actual
staged integer-list timing retained 20 randomised fresh-process blocks. Dual
inactive / direct C was 0.9898 with a paired 90% interval of
0.9750–1.0022, which crosses the predeclared margin and therefore does not
establish equivalence. The active delegating-observer control was 1.0684
relative to ordinary unobserved SR. A further 24-block replication covered
four staged shapes and retained 192 observations. Boolean and integer-list
familywise intervals fit ±2%, while Boolean-list and nested-list intervals did
not; point estimates ranged from 0.9955 to 1.0114. Recording mode, the complete
artefact workloads, end-to-end throughput, and second-machine replication
remain open; see `design/fail-faster-integration.md`.

The predeclared production structural-list comparison supplies one current
algorithmic-cost result: on three selected list properties it reduces paired
mean shrink calls by 72.52%, 72.94%, and 90.36% relative to current ordinary
lists, while preserving or improving exact-minimum rates. This supports the
specific structural representation; it is not a wall-clock result or blanket
performance parity with Hypothesis.

Across the eight selected subjects in `CURRENT-COMPARISON.md`, ordinary
Tapecheck matches Hypothesis's exact-minimum rate on the six original common
properties and exceeds it on the independently generated zig-zag and
head-equals-length schedules. Those latter rows also differ in discovery rate
and generated inputs, so they are useful selected complete-arm results rather
than proof that Tapecheck is generally better than Hypothesis.

## What to lead with when contacting the authors

1. **RO5:** the requested generator-assisted internal shrinking is working
   underneath unchanged Base Quickcheck generators, with persistence,
   resumption, and an honest input-side explanation phase.
2. **RO6:** successful OCaml tests now announce discarded counts and can report
   events, timings, shrink work, and proactive health checks.
3. **RO4:** edge-case-biased draws and opt-in structural generators show how
   the same choice representation can improve discovery and shrinking, while
   the unresolved default-list contract is stated explicitly.
4. **Integration:** this is not only a toy engine; a checked three-pin install
   builds an external PPX-using consumer, while a larger package-shaped
   consumer rebuilds Jane Street's `core` stack and proves an exact shrink
   with an atomic value shrinker.

Do not lead with “all of Hypothesis has been ported”, performance superiority,
automatic differential testing, complete state-machine parity, or the RO7 UI.
The credible message is that Hypothesis's choice-sequence architecture already
answers important requests in the paper, and Tapecheck demonstrates a measured,
OCaml-compatible route to adopting those answers.

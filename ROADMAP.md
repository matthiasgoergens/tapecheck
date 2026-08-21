# Tapecheck roadmap

This is the public roadmap for Tapecheck. It records durable technical
priorities rather than session state, branch tips, or private outreach plans.
Historical handoffs and raw experiment records belong in the companion
evidence repository.

## Current position

Tapecheck has two distinct stages:

1. **Wave 1** records and shrinks choices beneath existing
   `base_quickcheck` generators. The immutable checkpoint is `695082c`.
2. **Wave 2** develops the natural generator-layer evolution: continuation choices,
   structural spans, reorderable siblings, discarded attempts, and explicit
   recursive leaf budgets.

The product now has a checked three-pin opam preview. It installs replacement
`splittable_random` and `base_quickcheck` packages followed by `tapecheck`, then
builds an external PPX-using consumer against installed artefacts only. A
larger package-shaped consumer under `bonsai-tapecheck-hunt/` separately tests
real `core`-dependent code. A normal single-package release should still wait
until the interception seam can be supplied by upstream
`splittable_random`; the replacement pins are an evaluation route, not the
desired permanent dependency story.

## Before outreach

### 0. Correct the public upstream record

`janestreet/splittable_random#2` remains open, but its description and an early
comment cite the old minimum-of-five benchmark. A same-body study exposed an
avoidable inactive-path wrapper; after its removal, a separately predeclared
60-pair confirmation bounded the three measured primitive-loop costs below 5%
on one host. The submitted v1 diff also leaves split children
hook-free, whereas current generated-function support requires keyed observer
propagation. `design/upstream-pr-splittable-random.md` audits the exact gap and
`proposals/COMMENT-splittable_random-2.md` contains a factual draft correction.
Obtain Matthias's approval before posting it; do not point paper authors at the
thread while knowingly leaving the stronger stale claims unexplained.

### 1. Keep the published evidence reproducible

A [public companion evidence repository](https://github.com/matthiasgoergens/tapecheck-evidence/commit/ade578a729359dfcc954320089a5cde7207e62a8)
preserves the first experiment batches, the pinned Hypothesis baseline, a
current Wave 2 shrink-table checkpoint, and negative results. `EVIDENCE.md`
pins its immutable commit and maps product claims to their artefacts. When
making quantitative claims externally:

- keep the imported legacy outputs labelled as incomplete rather than
  promoting them into headline evidence;
- include source revisions, seeds, environment metadata, and reproduction
  commands; and
- change product documentation to link to immutable evidence commits.

Do not silently promote legacy measurements with incomplete provenance. Label
them historical, rerun them under a controlled design, or remove the numerical
claim from the public summary.

### 2. Decide the Wave 2 list contract

The measured online combination of continuation spans and a running size
budget is not suitable as the default list generator. It restores the size
bound and eliminates observed leaf-cap retries, but changes the generated
length distribution and substantially increases shrink cost. See
`PROBE-LIST-DESIGN.md` and the tracked result under
`probe_list_design/results/`.

The next design decision is explicit: either reserve future structural budget
without pre-recording the complete length, or adopt and document a different
size/distribution contract. PR #29 should not be described as superseded by
the measured online-budget arm.

A separately predeclared payload-only budget has now tested the simplest
relaxed contract as well. It restores length reachability and records no
leaf-cap retries, but permits aggregate strings above `size`, regresses the
hardest flat shrink case, and exceeds its shrink-cost screens. It is retained
as another negative result, not a production candidate.

The remaining scalar online-budget idea is ruled out by the causality argument
in `design/continuation-budget-trilemma.md`: retaining full length support, the
current aggregate bound, and continuation/element adjacency forces every
element size to zero. The next design must instead add an atomic
length-and-suffix edit, support non-contiguous structural mappings, or expose an
explicitly two-dimensional size contract. It should not try another formula
inside the same impossible three-way constraint.

### 3. Maintain the headline comparison at immutable revisions

The README's main table is a preserved historical Wave 1 result from
`13fbd09`, not from the final Wave 1 endpoint as previously implied. Checked
per-seed reruns now cover the table source, final Wave 1 at `695082c`, current
Wave 2, the six common Hypothesis properties, and the production structural
list arm. Final Wave 1 and current Wave 2 are byte-for-byte identical on all
1,600 stock/tape observations; the modest call-count drift from the README
table happened earlier within Wave 1. The structural arm retains ceiling
quality on two list properties with about 73% fewer shrink calls, and improves
the long-range list case from 47/100 to 99/100 exact with 90% fewer paired
calls. `CURRENT-COMPARISON.md` is now generated from the retained summaries and
distinguishes:

- Base's stock shrinker on the same original used by the ordinary tape arm;
- the final Wave 1/current ordinary tape engine;
- the production Wave 2 structural-list representation; and
- the independently generated pinned Hypothesis baseline.

Use identical property definitions and seed sets where the frameworks permit
it, retain individual observations, and report quality and cost separately.
All inputs to the selected eight-property matrix are retained individually.
Before publication, replace the local evidence pin with an immutable public
commit URL and regenerate the matrix from that published revision.

For a Jane Street adoption decision, add a separate performance experiment
against the staged and fast-randomness stack described in
[*Fail Faster*](https://arxiv.org/abs/2503.19797). It should compare the unused
seam, recording mode, and staged generators while preserving generator
semantics pointwise. The current unused-seam evidence replaces the historical
min-of-five timing with a same-body upper-bound study and a separately
predeclared confirmation after optimising the inactive path. All three
primitive-loop familywise upper bounds are below 2.6%, passing the predeclared
5% rule on one host. A source audit of the now-public artifact
found that its ordinary staged backend already reaches the seam, while its C
drop-in backend bypasses ordinary sampling calls. Backend-facing `run_*`
dispatch and behavioural controls provide the required active wiring, but two
fresh-process batches show that using it on every primitive is materially too
expensive. That first AllegrOCaml patch is retained as a rejected design.
`Intercept.is_active` now supports the next design: select a direct generated
body once when untaped and an observed body when Tapecheck is active. The
one-time selection boundary meets the ±2% equivalence criterion for every
local primitive loop in separately predeclared primary and confirmation
batches. A local dual-code patch now compiles and passes selection and paired
Boolean smoke tests under BER MetaOCaml 4.14.1. The real interception seam has
also been backported to the artifact's `splittable_random` v0.16 dependency;
its primitive and split/perturb smoke tests pass, and the dual path invokes an
observer once per active Boolean value. On 20 fresh-process integer-list
blocks, dual inactive / direct C was 0.9898 with a paired 90% interval of
0.9750–1.0022; it therefore failed the predeclared ±2% equivalence criterion.
The active delegating-observer control was about 1.0684 versus ordinary SR.
A separately predeclared 24-block replication covered Boolean, Boolean-list,
nested-list, and integer-list workloads. Boolean and integer-list familywise
intervals fit within ±2%; list and nested-list intervals did not, so blanket
equivalence remains unproved despite point estimates between 0.9955 and
1.0114. The remaining work is complete artefact workloads, active recording,
end-to-end properties, and second-machine replication; see
`design/fail-faster-integration.md`.

### 4. Narrow and stabilise the supported API

Explicit `.mli` contracts now cover the tape representation, engine, runner,
statistics, health checks, explanations, persistence, and supported stateful
and bisimulation helpers. The package-shaped Core consumer compiles and runs
against those contracts in a fresh switch. The API guard now records values,
types, modules, exceptions, and nested signatures across all three core
libraries; it complements rather than replaces that consumer check.

The remaining boundary work is smaller and deliberate: eventually hide
failure/image record representations behind accessors where that does not make
the structural research APIs unusable. Experimental measurements and
structural helpers now live under `Tape_engine.Diagnostics`, while the
explanation engine's coordination surface is isolated under `For_explain`.
The engine's mutable statistics accumulator is also abstract: callers inspect
immutable snapshots, while the compatibility runner uses a deliberately narrow
accounting seam for cases it runs itself.

The random observer is now abstract as well. `Intercept.create` supplies
delegating defaults for optional callbacks, so split propagation, weighted
choices, spans, and future backend capabilities do not require clients to
construct an ever-growing public record. The pinned upstream reconstruction and
Core consumer snapshot cover this interface.

### 5. Finish the public narrative

Keep the README focused on the result a new reader can reproduce. Move
historical investigations and superseded designs behind a concise experiment
index. Any outreach message should say that Tapecheck ports Hypothesis-style
choice-sequence shrinking and several associated capabilities—not that it has
already ported all of Hypothesis or matched all of its shrink quality.

## Known technical frontier

The regression suite deliberately records unresolved quality gaps rather than
hiding them. Current examples include:

- 5/8 exact minima in the ported Hypothesis shrink-quality cases;
- 21/48 exact one-element minima in poisoned list/matrix cases;
- 161/200 global optima in the small exhaustive oracle; and
- 235 pairwise witnesses of non-optimal settled failures.

These are research targets, not failing tests. Changes which improve them must
also preserve generation semantics, bounds, determinism, and measured cost.

## Publication safety

No repository reorganisation should destroy evidence. Copy or move artefacts
only after their current state is committed locally, retain provenance when
splitting repositories, and verify every replacement link before removing the
old path. Publishing, pushing, or rewriting remote history remains a separate
explicit action.

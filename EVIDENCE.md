# Evidence manifest

This manifest separates claims which a clone can reproduce directly from
historical or companion-repository evidence. The public companion repository
is pinned to an immutable commit.

Evidence pin: `ade578a729359dfcc954320089a5cde7207e62a8`.
The [public commit](https://github.com/matthiasgoergens/tapecheck-evidence/commit/ade578a729359dfcc954320089a5cde7207e62a8)
contains the experiment paths used below.

## Product-repository evidence

| Claim | Source or command | Status |
|---|---|---|
| The historical Wave 1 table improves exact shrinking on eight selected unchanged-generator subjects | `design/shrink-table-results.txt`; table source commit `13fbd09` | Preserved raw summary; the final Wave 1 endpoint is separately measured below |
| Current exact shrink-quality frontier is 5/8 | `opam exec --switch=5.3.0 -- dune exec test_shrink_quality/test_shrink_quality.exe` | Deterministic regression guard |
| Poisoned containers reach 21/48 exact one-element minima | `opam exec --switch=5.3.0 -- dune exec test_poison_lists/test_poison_lists.exe` | Deterministic regression guard |
| Small exhaustive oracle reaches 161/200 global optima | `opam exec --switch=5.3.0 -- dune exec test_exhaustive_oracle/test_exhaustive_oracle.exe` | Exhaustive over each recorded 64-point subject space |
| Pairwise search retains 235 non-optimality certificates | `opam exec --switch=5.3.0 -- dune exec test_pairwise_witness/test_pairwise_witness.exe` | Deterministic negative evidence |
| Descendable spans improve poisoned trees from 12/34 to 34/34 | `opam exec --switch=5.3.0 -- dune exec test_poison/test_poison.exe` | Deterministic paired generator comparison |
| Core-dependent consumer code uses the tape engine and can shrink an atomic positive control exactly | `docs/testing-core-dependent-code.md`; run the three executables in `bonsai-tapecheck-hunt/` from the documented fresh switch | Package-shaped integration check, not an installability claim |
| The three-pin preview installs and works from an external PPX-using project | create a disposable OCaml 5.3 switch, then run `scripts/test_opam_install.sh SWITCH` | Installs replacement `splittable_random`, replacement `base_quickcheck`, and `tapecheck`; `install-smoke/main.ml` must run the `Tape_test` facade and report an exact engine shrink to `50` |
| Public API declarations and the consumer snapshot remain synchronised | `scripts/check_api_surface.sh`; `scripts/check_consumer_snapshot.sh` | CI-style source and interface guards |
| Relative Markdown evidence and source links resolve | `UV_CACHE_DIR=/tmp/tapecheck-uv-cache uv run python scripts/check_markdown_links.py` | Checks every tracked Markdown file target and numeric line fragment; external URLs are outside its scope |
| Pointwise-equivalent optimized randomness backends can record and replay through the tape seam | `test_bq/test_roundtrip.ml`; `design/fail-faster-integration.md` | Behavioural regression; the measured per-draw integration is rejected in favour of a whole-generator fast/observed split |

The complete product test suite is:

```sh
opam exec --switch=5.3.0 -- dune runtest --force
```

With the companion repository checked out beside the product at the pinned
commit, verify the cross-repository boundary with:

```sh
scripts/check_evidence_snapshot.sh
```

Set `TAPECHECK_EVIDENCE_DIR` when the checkout is elsewhere. The check requires
a clean companion checkout at the exact pin, compares the generated matrix,
and verifies the byte-exact legacy-import manifest.

## Companion evidence at the pinned commit

| Experiment directory | What it supports | Claim boundary |
|---|---|---|
| `experiments/continuation-lists/2026-08-20-1ebd6a7` | Continuation choices preserve the measured raw length distribution closely; interleaved spans improve the tested list shrink cases; the unbudgeted form violates aggregate size bounds | One deterministic harness and revision; not a distribution-equivalence proof |
| `experiments/continuation-lists/2026-08-20-7ef59cc-budgeted` | The tested online running budget restores aggregate bounds and removes observed leaf-cap retries | It changes list lengths, raises recursive shrink cost, and fails the separability positive control; it does not supersede the earlier design |
| `experiments/continuation-lists/2026-08-20-1961f0a-payload-budget` | A separately predeclared relaxed contract restores list reachability and avoids observed leaf-cap retries | It fails its size, hardest-case quality, and shrink-cost screens; retained as a negative result, not a production candidate |
| `experiments/headline-shrink-table/2026-08-20-86204ca-wave1-observations` | Reconstructs all 1,600 observations behind the historical table at its actual source, `13fbd09` | Instrumentation-only local archival commit; the table predates the final Wave 1 endpoint |
| `experiments/headline-shrink-table/2026-08-20-002ab36-final-wave1-observations` | All 1,600 observations at final Wave 1 commit `695082c` | Byte-for-byte identical to the current Wave 2 observations on these subjects |
| `experiments/headline-shrink-table/2026-08-20-4a0c75d-wave2` | Initial aggregate comparison which exposed drift from the historical table | Superseded for Wave attribution by the revision-pinned per-seed reruns |
| `experiments/headline-shrink-table/2026-08-20-5fc7212-observations` | All 1,600 current stock/Wave 2 per-seed observations and a checked aggregate analysis | Hypothesis uses corresponding seeded definitions rather than the same generated OCaml values |
| `experiments/headline-shrink-table/2026-08-20-c7309e4-hypothesis-observations` | All 600 pinned Hypothesis observations for the six common properties | Property calls include generation and shrinking, unlike Tapecheck's shrink-only count |
| `experiments/headline-shrink-table/2026-08-20-31dbc81-structural-arms` | Predeclared ordinary-versus-production-structural comparison on three list properties | Arm-level generator-plus-shrinker result; the generators intentionally do not share originals |
| `experiments/headline-shrink-table/2026-08-20-b7ec842-harder-hypothesis-observations` | All 1,100 harder Hypothesis observations, including zig-zag and `head = length` | Retains negative and favourable subjects; generation and call boundaries differ from OCaml |
| `experiments/headline-shrink-table/CURRENT-COMPARISON.md` | Generated eight-property public quality and algorithmic-cost matrix | Selected subjects, with incompatible cost boundaries displayed rather than normalised away |
| `experiments/hypothesis-baseline/2026-08-13-1acc7b1` | Exact tracked-file archive of the pinned Hypothesis 6.164.0 harness and raw outputs | Cross-language evaluation counts are not controlled timings |
| `experiments/intercept-overhead/2026-08-20-d436c9a` | Two separately predeclared 12-process batches replace the historical min-of-five unused-seam timing | Results vary by batch: only the faster float direction confirms; neither equivalence nor a stable overhead is established |
| `experiments/intercept-overhead/2026-08-21-f4c7634-bound` | Forty paired same-body measurements isolate the production inactive check and retain hardware counters plus an active-observer positive control | Negative result: the float familywise upper bound is 1.0951, exposing an avoidable wrapper/default-call boundary |
| `experiments/intercept-overhead/2026-08-21-b454796-optimised` | Separately predeclared 60-pair confirmation after the inactive public path enters the local default body directly | All three 5% upper-bound screens pass; point estimates are 0.9930, 1.0063, and 1.0190, with familywise upper bounds at most 1.0255 |
| `experiments/fail-faster-integration/2026-08-20-225a142` | Pins the public artifact and AllegrOCaml sources, verifies the audited files byte-for-byte, and checks the rejected per-draw C-backend patch | Source/API evidence for the first design; no complete-generator performance claim |
| `experiments/fail-faster-dual/2026-08-20-69d843f` | Preserves the dual-generated AllegrOCaml patch, real v0.16 observer backport, exact commands, and BER MetaOCaml smoke-test result | Primitive and split/perturb controls, both selection branches, 100 paired Boolean seeds, and active callbacks pass; no performance workload ran |
| `experiments/fast-backend-dispatch/2026-08-20-5035e8d` | Two separately predeclared batches isolate dispatch around the same pointwise-equivalent C primitives | Per-draw ratios replicate at roughly 1.14, 1.22, and 1.61; not complete-generator overhead and not the artifact toolchain |
| `experiments/fast-backend-selection/2026-08-20-299a7a7` | Two separately predeclared batches isolate one activity decision around complete direct/observed primitive loops | All three loops meet the ±2% equivalence criterion in both batches; this is the precursor boundary, not the later AllegrOCaml workload result |
| `experiments/fail-faster-dual-performance/2026-08-20-69d843f` | Twenty randomised fresh-process blocks time actual dual-generated staged integer lists against direct C, plus an active delegating-observer control | Inactive ratio 0.9898, paired 90% interval 0.9750–1.0022: the ±2% equivalence criterion is not met; one host and one workload |
| `experiments/fail-faster-dual-multi/2026-08-20-69d843f` | Twenty-four paired blocks across Boolean, Boolean-list, nested-list, and integer-list staged workloads | Boolean and integer-list familywise intervals fit ±2%; list and nested-list intervals do not, so blanket equivalence is not established; all 192 observations retained |
| `experiments/computed-repair/legacy-2026-08` | Historical paired observations from the computed-repair investigation | Legacy import with incomplete environment provenance; not publication-grade |
| `experiments/size-dependence/2026-08-20-1ebd6a7` | A focused reproducer for size-dependent replay behaviour | Exploratory only |
| `experiments/shrinking-challenge/legacy-2026-08` | Five raw 1,000-seed outputs cited by historical design notes | Legacy import from an unversioned workspace; digests and modification times retained, incomplete environment provenance |
| `experiments/stats-accounting-issue-1/legacy-2026-08` | Original issue drafts and reproducers behind the stats-accounting fix | Historical; current `test_stats_accounting` is authoritative |
| `experiments/oxcaml-packaging/legacy-2026-08` | Logs from the historical public-overlay dependency investigation | Environment-specific historical diagnostics, not a current overlay claim |

## Claims not yet ready for outreach

- General quality or performance parity with Hypothesis is not established;
  the generated matrix supports only its selected subjects and stated cost
  boundaries.
- The optimised unused-seam result is a single-host, OCaml 5.3.0 primitive-loop
  bound. It supports less than 5% inactive overhead for the three measured hot
  loops, not zero cost, cross-machine equivalence, or end-to-end throughput.
- The open `splittable_random` PR still contains an obsolete unused-cost claim
  and a v1 split contract; the unposted correction is retained under
  `proposals/COMMENT-splittable_random-2.md`.
- Legacy Shrinking Challenge and packaging artefacts now have
  provenance-preserving imports, but their incomplete environment records make
  them audit trails rather than publication-grade performance evidence.

The product checks the companion checkout against the immutable pin above;
advance it only with a reviewed evidence commit and corresponding documentation
update.

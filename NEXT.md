# NEXT — tapecheck, 2026-08-20

## Goal
Port Hypothesis's Conjecture engine to `base_quickcheck`, measure honestly, then
send the outreach email to the ICSE-2024 PBT paper authors.

## State (verified)
- master `9c5a179`, full suite green (25 assertions across 30 test dirs),
  **0 open issues**, 1 open PR (#29, draft). CI green on the last master push.
- **All four** Hypothesis span-dependent passes exist (`remove_discarded`,
  `pass_to_descendant`, `reorder_spans`, `minimize_duplicated_choices`), merged
  via #32/#33 with 3/3 CI each — the first CI this work ever had.
- Span tree is now RECORDED, not inferred (`113b59b`): spans carry `id` and the
  id of their nearest retained ancestor, resolved in `Tape.finish`; `depth` is
  derived from that chain. `reorder_spans` asks for children by id, as
  Hypothesis's shrinker does (`span.children`).
- Guards two-sided and kill-tested: poison 12/34 floor+ceiling
  (`test_poison.ml:238`), poisoned lists 21/48 (`test_poison_lists.ml:169`),
  dup-pass cost ceiling 105 (`regression_guard.ml:301`, 98 on / 110 off).

## Property suites added this session (all kill-tested)
- `test_span_invariants` — span bounds, nesting, depth monotonicity, and the
  `reassemble_interval` laws (identity, length, permutation, precondition
  rejection).
- `test_encoding_laws` — the decoder law: moving choices toward target must not
  LENGTHEN the re-recording. 0 growth on master, **+38/+18 on
  wave2/monotone-list-sizes**, which is #29's defect.
- `test_cheap_laws` — serialise round-trip, idempotence, shortlex order axioms
  over 90k pairs, `?domains` invariance, resume-fixpoint. Last two carry
  explicit non-vacuity assertions.
- `test_no_raise` — generated corruption programs (operators drawn per seed, not
  a fixed corpus) against the deserialiser and replay/resume. AFL-shaped
  mutational fuzzing; lacks coverage feedback and crasher minimisation.

## Mutation experiment (artefacts in `tapecheck-notes/mutation-experiment-*.txt`)
5 plausible mutations; 3 caught by simple properties, 1 anchor-missed, and **1
survived the entire suite**: advancing the reassembly cursor to a child's START
rather than its stop. Replay re-records and repairs the malformed proposal, so no
outcome moved — only the SPREAD of answers (bound5: 1 → 17 distinct at 200
seeds). Trap worth remembering: **`exact` went UP under the bug** (0 → 44/200),
so a guard on exactness would have rewarded it.
Fixed two ways: a distinct-answer guard in `test_reorder` (bound 2; correct 1,
mutant 3 — a first draft bounded at 3 failed its own kill-test), and by
extracting `reassemble_interval` so the bug now fails 3 laws on 199/199 subjects
in a unit test.

## The open decision: PR #29 (monotone list sizes)
Fixes a real defect: the DECODER redistributes size into survivors when a list
shortens, so the tape grows (206→253), length never shrinks, and `converged` is
falsely reported. Re-measured on current master: deletion 17→734/1000,
nestedlists 18→482, coupling 18→439, plus two unrecorded improvements the new
two-sided guards caught (poisoned containers 21→39/48, `self_len` 47→**88**/100
vs Hypothesis's 53).
Three encodings measured (`pr29-three-encodings-20260818.txt`), none dominates.
skip-draw breaks the target-is-minimum invariant (all-targets 82 choices vs a
typical 62); always-draw is worst on quality; fixed-rate keeps the invariant but
costs coupling 439→210.
**Prior art says the budget itself is the defect.** Hypothesis rejected
QuickCheck sizing in 2015 (nesting multiplies); today it uses per-collection
`p_continue` continuation bools, `COLLECTION_DEFAULT_MAX_SIZE = 10**10`, an 8 KiB
entropy cap, and `max_leaves` for recursion. `average_size` was deprecated in
**3.51.0, 2018-03-24** (`hypothesis/docs/changelog.rst:14208`, verified):
"it is more effective to simply describe what constitutes a valid example, and
let our internals handle the distribution."

## Next 3 actions
1. **Run the continuation-list probe.** `list_structural` exists on master;
   `WAVE2-CONTINUATION-LISTS.md` shelved it pending "the span seam and an
   element-span deletion pass", a condition met last week and never re-tested.
   If it delivers, #29 closes as superseded rather than merged-then-undone.
2. Decide #29 on that result; if it disappoints, merge **fixed-rate** and note
   the intent to move to the Hypothesis encoding. Do NOT merge skip-draw as-is.
3. The outreach email (`~/prog/coordinate-work/outreach/email-draft-SHORT.md`,
   `f30e7e2`) — parked at Matthias's request, unsent. Its "two of the four
   passes" claim is now stale in our favour: all four exist.

## Unverified beliefs
- The three-encoding numbers are ONE 1000-seed run per arm on identical seeds.
  Large quality moves are far outside noise; sub-1% cost moves are not claimed.
- `proposals/base_quickcheck-non_uniform.patch` has an absolute path from before
  the directory consolidation, so the documented `+patch` reproduction fails with
  `git apply` (`patch(1)` works). Not yet fixed.
- codex has been quota-blocked since 2026-08-18; the last two sessions' diffs
  have had kimi review but no codex review.

## Refuted — do not resurrect
- "The dup pass zeroes duplicated STRUCTURAL draws." False: accepted proposals
  preserve image length (80→80) at payload positions. The trap was pass ORDERING.
- "A value-aware sort key fixes bound5's permutation." It generates the right
  proposal; the whole-image acceptance gate rejects it.
- "depth d implies a retained parent at depth d-1." False: depth counted
  unretained spans. Now moot — parentage is recorded (`113b59b`).
- "Generating the trivial image with forced targets fixes trivialization on #29."
  It does not: the generated all-targets image is 82 choices vs best's 62, so it
  is genuinely not smaller.

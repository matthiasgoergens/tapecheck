# NEXT — tapecheck, 2026-08-20

## Goal
Port Hypothesis's Conjecture engine to `base_quickcheck` and measure it honestly.
Immediate arc: close the span-dependent shrink-pass gap, then send the outreach
email to the ICSE-2024 PBT paper authors.

## State (verified this session)
- master `3385439`, CI green, **0 open issues**, 1 open PR (#29, draft).
  `gh pr list --state open` → only #29; `gh issue list --state open` → 0.
- **All four** Hypothesis span-dependent passes now exist on master
  (`remove_discarded`, `pass_to_descendant`, `reorder_spans`,
  `minimize_duplicated_choices`). Merged via #32 and #33, 3/3 CI each — the
  first CI this work ever had (`ci.yml` only triggers on master push / PR→master).
- Poisoned trees: 12/34 unchanged generators, **34/34** with the opt-in
  descendable capability (`test_poison/test_poison.ml:238`, floor AND ceiling).
- `minimize_duplicated_choices` enabled by default, **placement load-bearing**:
  run before the deletion/lowering passes it costs poisoned containers 21/48→17/48.
  Late it is 21/48 and buys `difference_must_not_be_zero` 98.0→85.5 mean evals.
- Guards now two-sided (improvements fail, not just regressions):
  `test_poison_lists.ml:169` recorded=21, `regression_guard.ml:301` max_avg_calls=105
  (98 pass-on vs 110 pass-off — kill-tested BOTH directions).
- Issue #2 closed with a measured negative result: the zero-cooperation "constant
  work" signal for vacuity is **unsound**, not merely imprecise — a vacuous
  property and a legitimately O(1) one are indistinguishable
  (`tapecheck-notes/vacuity-probe/results-2026-08-18.txt`).
- #20 closed (design note superseded by events; its span-cost prediction held).

## Cross-model review
codex is rate-limited (quota, retry 11:30). **kimi** reviewed the session diff
(`kimi -p ...`, exit 0) and found 4 defects, all fixed in `3385439`:
- [P2] `reorder_spans` bounds-checked children but not the PARENT span, whose
  interval feeds `Array.sub` directly → would raise outside `attempt` and abort
  the whole shrink. Unreachable today; fixed as an asymmetry, not a live bug.
- [P2]×3 stale/mixed-date numbers in `CHALLENGE.md` + the porting write-up.
No unresolved findings.

## The open decision: PR #29 (monotone list sizes)
Fixes a real defect on master: shortening a list makes the *decoder* redistribute
size into survivors, so the tape grows (206→253 choices), length never shrinks,
and the engine falsely reports `converged`. Re-measured on current master
(`tapecheck-notes/pr29-remeasure-vs-current-master-20260818.txt`): deletion
17→734/1000, nestedlists 18→482, coupling 18→439 — orthogonal to the span passes.
Also causes two *unrecorded improvements* the new two-sided guards caught:
poisoned containers 21→39/48, `self_len` 47→**88**/100 (Hypothesis: 53).

Three encodings measured (`pr29-three-encodings-20260818.txt`); none dominates:
- skip-draw (as written): best coupling/self_len, but **all-targets is 82 choices
  vs a typical 62** — the shrink target is not the shortlex minimum, breaking an
  assumption every pass relies on. Trivialization 1→555 attempts.
- always-draw: invariant correct, worst quality (nestedlists 136, coupling 164).
- fixed-rate: invariant correct, trivialization 1 attempt, nestedlists **491**,
  but coupling 210, self_len 66, size sum weakens to ~size²/2.

**Prior art says the budget itself is the defect.** Hypothesis rejected
QuickCheck-style sizing in 2015 (drmaciver.com/2015/08/a-vague-roadmap-for-hypothesis-2-0/):
nesting multiplies (list-of-lists quadratic, cubic at three deep); the fix is
"draw from the conditional distribution of values which are <= some maximum size"
— a bound, not a budget. Today: per-collection `p_continue` continuation bools
(`conjecture/utils.py:262-290`), `COLLECTION_DEFAULT_MAX_SIZE = 10**10`, one 8 KiB
entropy cap, recursion bounded by `max_leaves`. Each element costs one bool whose
target is *stop*, so all-targets is always the SHORTEST tape — the #29 inversion
cannot arise.

## Next 3 actions
1. **Run the continuation-list probe.** `list_structural` already exists on master;
   `WAVE2-CONTINUATION-LISTS.md` shelved it pending "the span seam and an
   element-span deletion pass" — that condition was met this week and nobody has
   re-run it. If it delivers, #29 closes as superseded instead of merged-then-undone
   (merging any variant forces recording frontier baselines that a later switch moves again).
2. Decide #29 on the probe's result: if it disappoints, merge **fixed-rate**
   (conservative: keeps the invariant, fixes false `converged`) and note the intent
   to move to the Hypothesis encoding. Do **not** merge skip-draw as-is.
3. The outreach email (`~/prog/coordinate-work/outreach/email-draft-SHORT.md`,
   commit `f30e7e2`) — parked, unsent, at Matthias's request. Now materially
   stronger: "two of the four passes" has become all four. Update that claim before
   sending.

## Unverified beliefs
- The `average_size` deprecation in Hypothesis 3.51.0 (2018-03-24) is **reported by
  web search, not verified** — the changelog is JS-rendered and the repo layout moved.
  The direction is confirmed by code (`average_size` is computed internally now).
- The three-encoding numbers are ONE 1000-seed run per arm on identical seeds. The
  large quality moves are far outside noise; the sub-1% cost moves are not, and are
  not claimed.
- `proposals/base_quickcheck-non_uniform.patch` has an absolute path from before the
  directory consolidation, so the documented `+patch` reproduction fails with
  `git apply`; `patch(1)` works. Not yet fixed.

## Refuted earlier this session — do not resurrect
- "The dup pass zeroes duplicated STRUCTURAL (dimension) draws." **False.** The
  accepted proposals preserve image length (80→80) at payload positions; seven
  duplicated 1s cannot be matrix dimensions. The trap was pass ORDERING.
- "Deletion+resample explains the poisoned-containers trap." Real phenomenon, but a
  SEPARATE one — it is why an all-equal-ints regression test cannot work, not why
  the guard regressed.
- "A value-aware sort key fixes bound5's permutation." Generates the right proposal;
  the whole-image acceptance gate rejects it, because a permutation preserves length
  and the first differing choice ranks the other way.

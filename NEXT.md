# NEXT — tapecheck, 2026-08-20

## Goal
Port Hypothesis's Conjecture engine to `base_quickcheck`, measure honestly, then
send the outreach email to the ICSE-2024 PBT paper authors.

## State
- master `4c486c7`, suite green across **33 test dirs**, **0 open issues**,
  1 open PR (#29, draft). CI green on last master push.
- **All four** Hypothesis span-dependent passes exist, merged via #32/#33.
- Span tree is RECORDED, not inferred (`113b59b`): spans carry `id` and the id
  of their nearest retained ancestor, resolved in `Tape.finish`; `depth` derives
  from that chain. `reorder_spans` asks for children by id, as Hypothesis does.
- `reassemble_permutation` (`b442eae`) returns an index MAPPING, so rearrangement
  is a permutation by construction and the mapping is a checkable witness.

## Test suites added (all kill-tested)
| suite | what it pins |
|---|---|
| `test_span_invariants` | span bounds/nesting/depth; permutation laws (bijection, identity outside children, contiguous blocks, precondition rejection) |
| `test_encoding_laws` | decoder law: moving choices toward target must not LENGTHEN the recording. 0 on master, **+38/+18 on wave2/monotone-list-sizes** |
| `test_cheap_laws` | round-trip, idempotence, shortlex order axioms (90k pairs), `?domains` invariance, resume-fixpoint |
| `test_no_raise` | generated corruption programs vs deserialiser and replay/resume (AFL-shaped; no coverage feedback yet) |
| `test_exhaustive_oracle` | **exact** minima by enumeration on 64 points. Engine optimal **161/200**, never beats the oracle. Only check here that knows the right answer |
| `test_enlarge_witness` | non-optimality certificates via enlargement; needs upward-closed properties |
| `test_pairwise_witness` | certificates from independently-found failures; no monotonicity needed. **235 certificates, all on `hd l = length l`** |

Optimality is NOT asserted anywhere: the landscape is high-dimensional and
jagged and every pass is hill-climbing, so 161/200 and 235 are recorded
two-sided as measurements of that cost, not defect counts. The useful signal is
concentration — `hd l = length l` yields 7 distinct answers and all 235
certificates; the other subjects yield 1 and 0. That separates well-handled
properties from the frontier without a per-property threshold.

## Mutation experiment (`tapecheck-notes/mutation-experiment-*.txt`)
5 mutations: 3 caught by simple properties, 1 anchor-missed, **1 survived the
whole suite** — advancing the reassembly cursor to a child's START. Replay
re-records and repairs the malformed proposal, so no outcome moved; only the
SPREAD of answers did (bound5 1 → 17 distinct). Trap: **`exact` went UP** under
the bug (0 → 44/200), so guarding exactness would have rewarded it. Fixed by a
distinct-answer guard AND by extracting the function so the bug now fails 3 laws
on 199/199 subjects.

## Open decision: PR #29 (monotone list sizes)
Unchanged from before. Fixes a real defect (decoder redistributes size on
shortening, so tapes grow and `converged` is falsely reported), gains survive on
current master (deletion 17→734/1000, nestedlists 18→482, coupling 18→439), and
brings two unrecorded improvements (poisoned containers 21→39/48, `self_len`
47→**88**/100 vs Hypothesis's 53). Three encodings measured, none dominates.
**Prior art says the budget itself is the defect** — Hypothesis has no size
parameter; `average_size` deprecated in **3.51.0, 2018-03-24**
(`hypothesis/docs/changelog.rst:14208`, verified): "more effective to simply
describe what constitutes a valid example, and let our internals handle the
distribution."

## `~size` is ambient state, and the same story
`Generator.generate ~size` is an input to the DECODER that is not on the tape, so
a tape alone does not determine a value. Already handled where it matters: the
failure DB persists `"<size>\n<image>"` (`tape_db.ml:135-142`, with a comment
recording the exact bug — it once replayed everything at `sizes.(0)`) and the
regression files do too (`tape_test.ml:87`). NOT handled at the `Tape.image`
level, so ad-hoc callers can mismatch — it silently cost two of three subjects in
`test_pairwise_witness`. Hypothesis's structural answer is to have no size
parameter at all, which is the same fix as #29.

## Tooling to look into
- **`mutaml`** (github.com/jmid/mutaml) — OCaml mutation tester by Jan Midtgaard,
  the `qcheck-stm` author this repo benchmarks against. Candidate to ADOPT: a
  hand-rolled 5-mutation experiment already found a real gap. Also
  `theofidry/awesome-mutation-testing` for the field.
- Formal names for the claim behind it: **competent programmer hypothesis** and
  **coupling effect**. Read before leaning on mutation scores.

## Next 3 actions
1. **Run the continuation-list probe.** `list_structural` exists on master;
   `WAVE2-CONTINUATION-LISTS.md` shelved it pending the span seam and an
   element-deletion pass — met last week, never re-tested. If it delivers, #29
   closes as superseded rather than merged-then-undone.
2. Decide #29 on that result; if it disappoints, merge **fixed-rate** and note
   the intent. Do NOT merge skip-draw (it breaks target-is-minimum).
3. The outreach email (`~/prog/coordinate-work/outreach/email-draft-SHORT.md`,
   `f30e7e2`) — parked, unsent. Its "two of the four passes" claim is now stale
   in our favour: all four exist.

## Unverified
- Encoding numbers are ONE 1000-seed run per arm on identical seeds.
- `proposals/base_quickcheck-non_uniform.patch` has a pre-consolidation absolute
  path, so the documented `+patch` reproduction fails with `git apply`
  (`patch(1)` works). Unfixed.
- codex quota-blocked since 2026-08-18; recent diffs reviewed by kimi only.

## Refuted — do not resurrect
- "The dup pass zeroes STRUCTURAL draws." False: proposals preserve length
  (80→80) at payload positions. The trap was pass ORDERING.
- "A value-aware sort key fixes bound5." Right proposal, rejected by the
  whole-image acceptance gate.
- "depth d implies a retained parent at d-1." False (depth counted unretained
  spans); now moot, parentage is recorded.
- "Forced-target generation fixes trivialization on #29." No: the all-targets
  image is 82 choices vs best's 62, genuinely not smaller.
- "size(shrink(A)) <= size(B) for independent failures A, B." False — local
  optima. Only the asymmetric half (certificates) is usable.

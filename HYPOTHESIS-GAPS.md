# Where Hypothesis is still ahead

Measurements compiled 2026-08-09 at `3aa0a47`; status text refreshed during
the Wave 1 close-out on 2026-08-10. Every number was measured in that
tree, or is a `grep` you can re-run; nothing is carried
over from an older write-up, because carrying numbers over is exactly
how `CHALLENGE.md` came to report 716/1000 for a row that measures
1000/1000.

Method: my own audit of the code, plus independent passes from two other
model families (codex against the live source and current upstream,
DeepSeek against the write-ups). Where they disagreed I resolved it by
checking the tree, and those resolutions are recorded — one of them
changes the answer.

## 1. Shrink quality, measured

Four ports of Hypothesis's own quality tests exist here, so the
comparison is against their test rather than against a story.

| harness | tapecheck | Hypothesis | what it measures |
|---|---|---|---|
| `challenge/` (Shrinking Challenge, n=1000) | 4/9 normalised | 9/9 | cross-language shrink quality |
| `test_poison/` | 12/34 | 34/34 | poison-position reduction in trees |
| `test_poison_lists/` | 21/48 | 48/48 | the same for lists and matrices |
| `test_shrink_quality/` | 5/8 | 8/8 | exact-minimum assertions |
| `self_len` (in `test_regression/`) | 47/100 | 53/100 | long-range dependency |

The five challenge losses, with mean evaluations, stock arm:

| challenge | tapecheck | Hypothesis |
|---|---|---|
| reverse | 0/1000, 293.8 | 1000/1000, 17.7 |
| distinct | 0/1000, 436.7 | 1000/1000, 49.1 |
| large_union_list | 0/1000, 1338.8 | 1000/1000, 211.3 |
| calculator | 16/1000, 912.0 | 1000/1000, 103.3 |
| bound5 | 158/1000, 276.8 | 1000/1000, 154.8 |

Cost matters as much as quality here: `reverse` is not just lost, it is
lost while spending 17x the evaluations.

The three `test_shrink_quality` gaps are worth naming individually,
because two of them point at the same structural cause as §3:

- long bool list should reach exactly 70 falses; reaches len 137, 75 true
- list of strings should reach 10 empty strings; reaches 12 strings, 11 chars
- nested bool lists should reach five copies of `[false;true]`; reaches 7
  ragged inner lists

## 2. Missing shrink passes

`grep` count in `engine/tape_engine.ml`, 2026-08-09:

| Hypothesis pass | here |
|---|---|
| `pass_to_descendant` | absent (1 hit, a comment saying it is blocked) |
| `remove_discarded` | absent (0 hits) |
| `minimize_duplicated_choices` | absent (0 hits) |
| `reorder_spans` | `sort_siblings` exists — **and is hard-disabled** |
| string/unicode character passes | absent, and unrepresentable (§3) |

`sort_siblings` is the interesting one and it is not simply missing.
`engine/tape_engine.ml:1789` sets `sort_siblings_enabled = false`, with a
recorded reason, re-measured at n=1000 on 2026-08-09 rather than merely
quoted. The live engine comment now records the full trade:

| challenge | stock, off | stock, on | +patch, off | +patch, on |
|---|---|---|---|---|
| distinct | 0 | 0 | 116 | **649** |
| reverse | 0 | 0 | 452 | 487 |
| binheap | 93 | **110** | 93 | **110** |
| bound5 | 158 | 159 | 52 | **0** |
| calculator | 16 | 12 | 14 | 14 |
| large_union_list evals | 1338.8 | **1671.1** | 1306.2 | 1560.9 |

What reproduces from the earlier justification: the `large_union_list` cost
penalty (24.8%), and the large `distinct` gain once the patch equalises sibling
draw counts (11.6% → 64.9%). The live comment has been refreshed to record
these n=1000 measurements.

What did **not** reproduce was the original headline reason for keeping it off.
The old comment cited bound5 at 12.5% against 15.9% on stock; at n=1000 both
arms are 15.8–15.9% and the pass makes no difference there. The comment
was measured at n=100 and admits its intervals overlapped — so that half
of the justification was noise, and it has been carrying the decision
since.

Two effects the old comment did not record, both real at n=1000: binheap
improves 93 → 110 on stock (and 299 → 327 at-or-below optimal size), and
bound5 collapses 52 → 0 on the patched arm. The live comment now includes
both. So the trade is not "nothing on stock, everything with the patch"; it is
a genuine trade in both arms.

The structural point stands regardless: one of our shrinker gaps is
**downstream of an upstream encoding defect**, and the biggest single
win available (distinct, 0 → 649/1000) needs a patch that has not been
filed.

Pass *scheduling* is also weaker: `shrink` runs a fixed order, where
Hypothesis's `fixate_shrink_passes` reorders by productivity and uses
`ChoiceTree` to resume a pass where it left off. Only `lower_and_delete`
here has an adaptive rule (earned patience).

## 3. The choice IR is narrower than Hypothesis's

This is a real longer-term gap. External Wave 2 evidence on the deliberately
unmerged `bug/nested-list-length` branch (PR #28) shows that the poor
list-of-strings result above is primarily caused by `base_quickcheck`'s
anti-monotone list budget redistribution, not by the lack of a first-class
string choice. That reproducer is not part of this Wave 1 tree.

Hypothesis's provider draws five choice types —
`draw_boolean`, `draw_integer`, `draw_float`, `draw_string`,
`draw_bytes` (`providers.py`). `tape/tape.ml:21` has three plus a
marker: `Integer`, `Float`, `Bool`, `Marker`. Strings and bytes are not
choices at all; they decompose into integer draws, so there is nothing
for a string-aware pass to grip. Hypothesis shrinks a string *as a
string*; here it is an unlabelled run of ints.

Also narrower: integers are `int64` where Hypothesis has arbitrary
precision, and floats carry finite `lo`/`hi` where Hypothesis's float
domain includes NaN and the infinities as first-class shrink targets.

Underneath all of it is the known one: no spans, so no labels, no
nesting, no discard flags. `SPANS-THE-ROOT-CAUSE.md` has the full
argument and `test_poison` prices it.

**The source-constant pool.** Hypothesis's provider scans the test's own
source for literals and biases generation toward them
(`_get_local_constants`, `_maybe_draw_constant`). `biased_int` and
`biased_float` here have fixed boundary heuristics only — the ends of
the range, one step in, the shrink target, a weighted bit-size — and
`tape/tape.ml:272` says the omission is deliberate: the pool "has no
OCaml analogue (and is a separate, heavier feature ... deliberately not
ported here)". Deliberate is not the same as absent-from-the-list: a
property that fails only on a magic number appearing in the test source
is one Hypothesis can reach and this cannot.

(Both external reviewers raised this and I dropped it from the first
draft of this document, which is a good argument for running them.)

## 4. Built, but not wired into the normal path

These are the ones both external reviewers got wrong in opposite
directions, so they are stated carefully. They exist — DeepSeek said
they did not, and it was reading stale markdown. But they are not
reachable the way Hypothesis's equivalents are, which is codex's point
and it is correct.

- **`target()`**: `Tape_engine.run_target` exists. There is no `target`
  in `Tape_stats` for a test body to call, no labels, no multiple
  objectives, no Pareto front (Hypothesis has `pareto.py`), and
  `Tape_test.run` never enters a target phase.
- **Example database**: `engine/tape_db.ml` exists. It stores one image
  per key and a new failure overwrites it, where Hypothesis keeps
  primary/secondary/Pareto corpora. It is opt-in and manually keyed —
  `Tape_test.result` requires both `?db` and `?db_key` (and rejects a
  half-configured pair) — where Hypothesis has a default database and
  derives test identity itself.
- **Multiple bugs**: `run_multi` exists and is referenced 0 times in
  `engine/tape_test.ml`. Hypothesis reports multiple bugs on the normal
  path, under `report_multiple_bugs`.

`MINING-BACKLOG.md` now distinguishes these partial integrations from the
richer Hypothesis surfaces that remain.

## 5. Exhaustion and determinism

Hypothesis's `DataTree` tracks explored choice-prefixes exactly, which
buys three things: exact exhaustion, novel-prefix generation, and
`Killed` subtrees. `Tape_engine.run:2441` approximates only the first,
by noticing a run of coincidental repeats, and says so. It is a
heuristic with a false-positive mode, and it is skipped entirely when
`~domains > 1`.

`check_generator_determinism` exists and *is* wired (called at
`tape_engine.ml:2680`), which is another place `MERGE-STATUS.md` is
stale. But it is 8 replays after a first failure, comparing images, and
warning-only — where Hypothesis detects inconsistency throughout
execution and raises `Flaky`. Test-predicate flakiness during search is
not detected at all; only the final materialised minimum is rechecked.

## 6. Settings, deadlines, phases

`Tape_engine.run` takes a pile of optional arguments; Hypothesis has a
`settings` object with profiles. Concretely missing: `Phase` control
(no way to run explain-only or skip shrinking), per-example `deadline`
(`max_seconds` bounds the whole run, and `Tape_health`'s `too_slow` is a
fixed one second on *generator* time, not test time), `derandomize`,
verbosity levels, and the alternative-backend/provider API that lets
Hypothesis run CrossHair.

## 7. Explain

`engine/tape_explain.ml` perturbs each tape choice and reports which
positions matter — it calls itself the input half. Hypothesis's explain
phase also traces branch/line coverage and names source lines. It cannot
be ported as-is: it needs `sys.monitoring`, and OCaml has no equivalent
(this is what `outreach/ocaml-tracing.md` is about). Structural, and not
structural about *us* — it is missing from the language.

## 8. Statistics and observability

`stats_to_string_hum` prints human text. Hypothesis emits observability
JSONL with per-case status, events, targets, stop reasons and timing.
Health checks here are four approximate analogues rather than ports:
`data_too_large` means "over 512 choices" rather than upstream's overrun
condition, and health accounting is absent under `~domains > 1`.

## 9. Stateful testing

`stateful/stateful.ml` is a command-sequence helper: one hand-written
state-dependent command generator, one initial state. Hypothesis's
`RuleBasedStateMachine` has `@rule`/`@initialize` discovery, Bundles
with `consumes`, `multiple()`, and rule targets. The port is coherent
and deliberately narrow; it is not parity.

## Two audit defects fixed during the Wave 1 close-out

Found while checking the above, and worth fixing regardless of the
comparison:

**`truncated_passes` was a dead counter.** It was declared, reset and
incremented but never read. A nearby comment also contradicted the deliberate
settling semantics implemented by `let converged = budget_ok ()`.

That looks like a bug and codex reported it as one. It is not: the
longer comment immediately below (1822-1844) deliberately reverses the
earlier one, on the reasoning that a pass stopping after
`max_pass_failures` *has* settled, so more budget would change nothing —
and records that an earlier version which kept the flag true cost 3.6x
down to 2x. The code implements the later decision. What is wrong is
that the superseded comment and dead counter were left behind. Both are now
removed.

**`Tape_db.save` used a fixed temporary name.** It now creates a unique
temporary file in the database directory before the atomic rename, so two
writers no longer share a staging path.

## How the three passes disagreed

Worth recording, since the disagreements were the informative part.

- DeepSeek had only the markdown, and reproduced its staleness: it
  reported `target()` and the database as absent, and quoted lengthlist
  at 716/1000. Reading the docs is what produced those errors — the docs
  were wrong.
- Codex read the code and was right about those, and additionally found
  the `sort_siblings` disable and the dead counter. It was wrong about
  the counter being a live defect, for the reason above.
- Both missed the choice-IR alphabet gap in §3, which came from diffing
  `providers.py`'s `draw_*` methods against `Tape.choice`.
- Both raised the source-constant pool and I dropped it from the first
  draft. A second DeepSeek pass — given the actual source instead of the
  markdown, and told explicitly which stale claims to avoid — refuted
  this document on exactly that omission. That is the single clearest
  argument in this session for running the external passes at all.

One item was proposed and is **rejected**: DeepSeek suggested that
`sampled_from`/enum not being a first-class choice is a gap. It is not a
gap *versus Hypothesis*, whose IR alphabet is the same five types with
no enum among them — `sampled_from` there is an integer index too. It
may still be a good idea; it is not a place Hypothesis is ahead.

No single pass would have produced this list.

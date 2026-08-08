# Where Hypothesis is still ahead

Compiled 2026-08-09 at `3aa0a47`. Every number here was measured in this
tree on that commit, or is a `grep` you can re-run; nothing is carried
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
`engine/tape_engine.ml:1792` sets `sort_siblings_enabled = false`, with a
measured reason: against *stock* `base_quickcheck` the pass is a net
negative (bound5 12.5% against 15.9%, `large_union_list` 23% dearer for
no gain), and it only pays once `proposals/base_quickcheck-non_uniform.patch`
equalises sibling draw counts — at which point `distinct` goes 11.6% to
69.5%. So one of our shrinker gaps is **downstream of an upstream
encoding defect**, and is unblocked by a patch that has not been filed.

Pass *scheduling* is also weaker: `shrink` runs a fixed order, where
Hypothesis's `fixate_shrink_passes` reorders by productivity and uses
`ChoiceTree` to resume a pass where it left off. Only `lower_and_delete`
here has an adaptive rule (earned patience).

## 3. The choice IR is narrower than Hypothesis's

This is the gap I had not seen written down anywhere, and it explains
the string result above.

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
  `Tape_test.result` silently does nothing unless *both* `?db` and
  `?db_key` are passed — where Hypothesis has a default database and
  derives test identity itself.
- **Multiple bugs**: `run_multi` exists and is referenced 0 times in
  `engine/tape_test.ml`. Hypothesis reports multiple bugs on the normal
  path, under `report_multiple_bugs`.

**`MINING-BACKLOG.md` is stale on the first two** — it lists `target()`
as "queued and unstarted" and the database as absent. Both landed.

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

## Two claims in this repo that the code does not support

Found while checking the above, and worth fixing regardless of the
comparison:

**`truncated_passes` is a dead counter.** Declared at
`tape_engine.ml:575`, reset at 865, incremented at 1507, and **never
read**. The comment at 1816 says "Report converged only if no pass was
ever truncated", and the code at 1845 is `let converged = budget_ok ()`.

That looks like a bug and codex reported it as one. It is not: the
longer comment immediately below (1822-1844) deliberately reverses the
earlier one, on the reasoning that a pass stopping after
`max_pass_failures` *has* settled, so more budget would change nothing —
and records that an earlier version which kept the flag true cost 3.6x
down to 2x. The code implements the later decision. What is wrong is
that the superseded comment was left sitting above it, contradicting it,
next to a counter that no longer does anything. It misled a careful
reader on its first encounter, which is the definition of a comment
worth deleting.

**`Tape_db.save` uses a fixed temporary name.** `tape_db.ml:185` writes
`file ^ ".tmp"` then renames. Two processes saving the same key race on
that one path. The rename-for-atomicity is right; the fixed name defeats
it.

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

No single pass would have produced this list.

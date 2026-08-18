# What is left to mine from Hypothesis

Survey of `hypothesis-python/src/hypothesis/`, 2026-07-31, after the
shrinker pass. Ordered by value, with what has already been taken marked.

**Read `HYPOTHESIS-VERSION.md` first.** Everything below was surveyed
against a 6.80.1 checkout; current is 6.164.0, and names and passes
changed substantially in the choice-sequence rework.

## Already mined

- `shrinker.py` — pass list, `fixate_shrink_passes`, `max_failures`,
  `lower_blocks_together` (**ported**), `pass_to_descendant` (read,
  blocked on spans), `remove_discarded` (read, blocked on spans),
  `minimize_duplicated_blocks`, `reorder_examples`.
- `junkdrawer.py` — `find_integer` (**ported**).
- `engine.py` — `MAX_SHRINKS` (**ported**), `max_stall` (measured,
  **rejected with evidence**), wall-clock deadline.
- `choicetree.py` — `prefix_selection_order` / `random_selection_order`
  (understood; blocked on passes being first class).
- `tests/quality/` — `test_zig_zagging` (**ported**, and we now lead on
  it), flatmap family (read; the `@flaky` finding).

## Not mined, highest value first

### 1. `datatree.py` — exact versions of two partially ported features

Tracks which choice-prefixes have been explored. Gives:

- **Exhaustion detection**: tapecheck now stops after a long run of repeated
  generated images, but this is a heuristic. Hypothesis's prefix tree knows
  when a finite search space is actually exhausted.
- **Non-deterministic generator detection**: tapecheck now replays and checks
  a bounded sample in normal `run`/`resume` paths. Hypothesis's DataTree tracks
  this continuously and exactly. Their message remains worth stealing:
  *"Inconsistent data generation! Data generation behaved differently
  between different runs. Is your data generation depending on external
  state?"* Raised as `Flaky`. A generator reading a clock or a global
  can still escape a bounded replay sample here.

Also `Killed` nodes: marking subtrees as not worth exploring.

### 2. ~~Learned shrink passes~~ — REMOVED FROM HYPOTHESIS, do not port

**Correction.** I ranked this second-most-valuable. It is not a parity
gap at all: `dfas.py`, `learned_dfas.py` and `dfa/lstar.py` exist in the
6.80.1 checkout I was reading and are **absent from 6.164.0**, along
with any DFA replacement pass. Removed upstream between the two.
Historical research, and I was about to spend real effort on it — see
`HYPOTHESIS-VERSION.md`. Kept below only because the idea is still
interesting to discuss.

Their description, in the version that had it:

> given a test function that sometimes shrinks to one thing and
> sometimes another, this module is designed to help learn new
> DFA-based shrink passes that will cause it to always shrink to the
> same thing.

So: **shrinker NORMALISATION via L\* automaton learning**, with the
learned DFAs checked into the repo and replayed as ordinary shrink
passes (`dfa_replacement(n) for n in SHRINKING_DFAS` in the pass list).
Nothing in the OCaml ecosystem is anywhere near this. See also
`tests/quality/test_normalization.py`.

Worth understanding even if not ported: "your shrinker is
non-deterministic and here is a way to measure and fix that" is a strong
thing to be able to discuss.

### 3. `optimiser.py` + `pareto.py` — richer targeting

`Tape_engine.run_target` now provides a single-objective kernel. What remains
is test-body `target()` calls, labels, multiple objectives, tape growth and a
Pareto front. Hypothesis's implementation is a hill climber that regenerates parts of a test case
(`optimiser.py`), and `pareto.py` maintains a Pareto front for
multi-objective targeting. Note it reuses `find_integer`, which we now
have. Their own docstring is refreshingly modest: *"not expected to
produce amazing results, because it is designed to be run [in a
limited budget]"* — that honesty is quotable.

### 4. `database.py` — richer failure corpora and defaults

`Tape_db` is wired through `Tape_test`: it replays the last failure first and
deletes stale entries after a fix. Hypothesis remains ahead with default test
identity and primary/secondary/Pareto corpora rather than one explicitly keyed
image.

### 5. `shrinking/{integer,lexical,ordering,floats}.py`

The individual shrinker primitives, as opposed to the passes that use
them. `ordering.py` in particular is the sort-into-order primitive
behind `reorder_examples`, and `Lexical` drives
`minimize_duplicated_blocks`.

### 6. Smaller

`statistics.py`/`control.py` (the port now has summaries, `assume`, and
`event`, but not the full surface), `provisional.py`, and the broader
`RuleBasedStateMachine` API beyond the deliberately narrower `Stateful` port.

## Beyond Hypothesis

**Mine real projects' use of PBT for benchmarks.** Everything measured
so far is synthetic — properties invented to stress a shrinker. Real
`base_quickcheck` properties from Jane Street's public repos would give
benchmarks with genuine generator shapes and genuine failure modes, and
"we profiled your actual tests" is a far better email line than "we made
up ten properties". Candidates already surveyed for the bisimulation
work: `core`, `base_test`, `incr_map`, `bonsai`, `higher_kinded`.
Profiling those would also test the ~85% bookkeeping finding
(`SPANS-THE-ROOT-CAUSE.md`) against real generator shapes rather than
`G.list` alone.

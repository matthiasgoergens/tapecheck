# What is left to mine from Hypothesis

Survey of `hypothesis-python/src/hypothesis/`, 2026-07-31, after the
shrinker pass. Ordered by value, with what has already been taken marked.

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

### 1. `datatree.py` — two distinct features, both absent here

Tracks which choice-prefixes have been explored. Gives:

- **Exhaustion detection**: knowing the search space is finished, so a
  run stops early instead of re-drawing the same cases. tapecheck has no
  notion of this.
- **Non-deterministic generator detection**, which is a health check we
  do not have at all. Their message is worth stealing verbatim:
  *"Inconsistent data generation! Data generation behaved differently
  between different runs. Is your data generation depending on external
  state?"* Raised as `Flaky`. A generator reading a clock or a global
  currently produces silent nonsense in tapecheck.

Also `Killed` nodes: marking subtrees as not worth exploring.

### 2. `shrinking/dfas.py` + `learned_dfas.py` + `dfa/lstar.py` — learned shrink passes

The most novel thing in the codebase and completely unmined. Their own
description:

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

### 3. `optimiser.py` + `pareto.py` — `target()`, already on the roadmap

`target()` is queued in `outreach/ro-roadmap.md` and unstarted. The
implementation is a hill climber that regenerates parts of a test case
(`optimiser.py`), and `pareto.py` maintains a Pareto front for
multi-objective targeting. Note it reuses `find_integer`, which we now
have. Their own docstring is refreshingly modest: *"not expected to
produce amazing results, because it is designed to be run [in a
limited budget]"* — that honesty is quotable.

### 4. `database.py` — failure replay across runs

tapecheck has `resume` from a pasted tape, which is the manual version.
A real database keyed by test identity, replaying last-known failures
first, is a distinct feature and a common ask.

### 5. `shrinking/{integer,lexical,ordering,floats}.py`

The individual shrinker primitives, as opposed to the passes that use
them. `ordering.py` in particular is the sort-into-order primitive
behind `reorder_examples`, and `Lexical` drives
`minimize_duplicated_blocks`.

### 6. Smaller

`statistics.py` (the RO6 reporting surface — the
`statistics-and-health` branch covers some of this), `control.py`
(`assume`, `note`, `event`), `provisional.py`, `stateful.py` (compare
against the port already made).

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

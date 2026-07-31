# Harder benchmarks: finding where tapecheck and Hypothesis differ

The original six (`demo/shrink_table.ml`) were built to expose
`base_quickcheck`'s stock shrinkers, which fail all six. Against
Hypothesis they are too easy — both score 100/100 and only cost
separates them. `harder_benchmarks.py` adds ten designed to be hard for
a Conjecture-class engine.

Hypothesis was run first deliberately, but NOT to discard cases it
fails. A case both engines fail is the frontier: it is where the port
could eventually beat the reference, which is a better story than
parity. Tagged as opportunities rather than dropped.

## Hypothesis results (100 seeds each)

| benchmark | found | fully minimal | worst |
|---|---|---|---|
| duplicate | 100 | 100 | - |
| unsorted | 100 | 100 | - |
| **self_len** (`l[0] == len(l)`) | 89 | **53** | `[8,0,0,0,0,0,0,0]` vs true `[1]` |
| **load_bearing** (`a==0 and b>=5`) | **78** | 78 | - |
| tree_depth | 100 | 100 | - |
| **rare_precond** (`assume(x%7==3)`) | 100 | **7** | `605` vs true `101` |
| two_lists | 100 | 100 | - |
| big_boundary (2^62, full range) | 100 | 100 | - |
| substring | 100 | 100 | - |
| nested | 100 | 100 | - |

Three discriminators, of different kinds:

- **self_len** — a *shrinking* weakness. Deleting an element breaks
  `l[0] == len(l)`; lowering `l[0]` breaks it too. Only a simultaneous
  edit works.
- **rare_precond** — an *assume/discard* weakness, 7/100. Related to the
  filtered-generator cost measured on tapecheck's side.
- **load_bearing** — a *generation* weakness: 78/100 found, but 78/78 of
  those shrink perfectly.

## self_len, head to head — prediction failed

tapecheck has a dedicated `lower_and_delete` pass for exactly this shape
(lower an integer while deleting a later choice), so the prediction was
a clear tapecheck win. Measured:

```
self_len -- 100 seeds
  stock     found  96/100, fully minimal  27/100, worst (10 35 21 50 40 38 14 17 31 49)
  tape      found  97/100, fully minimal  47/100, worst (10 0 0 0 0 0 0 0 0 0)
  hypothesis found 89/100, fully minimal  53/100, worst [8, 0, 0, 0, 0, 0, 0, 0]
```

**tapecheck 47 vs Hypothesis 53 — slightly worse, and stuck in the
identical trap** (a list of n zeros headed by n). The dedicated pass does
not rescue the case it was designed for, which is consistent with the
separate finding that `lower_and_delete` scores zero successes on list
properties.

tapecheck does find the bug more often (97 vs 89), which is the
edge-case-biased generation working.

This is the first benchmark where both engines are far from 100/100. It
is the most valuable one in the set for exactly that reason.

## Next: mine Hypothesis's own test suite

Their `hypothesis-python/tests/quality/` has a decade of hard cases
accumulated from real bug reports — far better than invented ones.
Worth porting:

- **`test_zig_zagging.py::test_avoids_zig_zag_trap`** — a *named*
  shrinker pathology (two values whose difference must stay 1, so
  lowering either alone fails), and it asserts a quantitative bound:
  `budget = 2 * n_bits * ceil(log(n_bits, 2)) + 2`. A shrink-cost test,
  not just a quality one. Highest value in the list.
- **`test_poisoned_lists.py` / `test_poisoned_trees.py`** — a rare
  "poison" element inside a container; the minimum is a one-element
  container holding it. Tests that finding it is not exponential.
  Parameterised over `LinearLists` and `Matrices`.
- `test_shrink_quality.py` — many, with exact expected minima:
  `test_duplicate_containment` (`[0,0]`), `test_containment`,
  `test_minimize_multiple_elements_in_silly_large_int_range_min_is_not_dupe`,
  `test_list_with_complex_sorting_structure`, `test_reordering_bytes`,
  `test_find_large_union_list`, the `flatmap` family.
- `test_float_shrinking.py`, `test_normalization.py`,
  `test_shrinking_order.py`, `test_integers.py`.

Their expected minima are stated as assertions, so they port directly
into `is_minimal` predicates.

## zig-zag: ported their test, then their defence — and now we win it

`test_zig_zagging.py::test_avoids_zig_zag_trap` is the only shrink-COST
test in Hypothesis's quality suite: two values must stay exactly 1 apart
to keep failing, so lowering either ALONE works by one step and never
more, and a shrinker without a joint move walks them down in lockstep.
They care enough to assert a bound, `2 * n_bits * ceil(log2 n_bits) + 2`.

Ported as a benchmark first, which showed tapecheck falling straight
into it:

```
zig-zag over [0,300], 100 seeds
  stock       found  80/100, fully minimal   0/100
  tape BEFORE found  83/100, fully minimal  51/100, avg 2929 calls
  tape AFTER  found  83/100, fully minimal  83/100, avg   30 calls
  hypothesis  found  67/100, fully minimal  67/100, avg  166 calls (gen+shrink)
```

Before the fix the budget was exhausted, which is *why* only half
reached the minimum — a cost problem presenting as a quality problem.

The defence is `lower_together`, a port of `lower_blocks_together`
(shrinker.py:1258): pick a non-zero integer choice, pick a later
non-zero one within 8 of lookahead, lower BOTH by the same k, and find
the largest workable k with `find_integer`. The difference is preserved,
so one galloping search covers the whole distance instead of O(value)
single steps.

**tapecheck is now ahead of Hypothesis here** — 83/100 found and
minimal against 67/100. The found-rate comparison is clean; the call
columns are not directly comparable because Hypothesis's includes
generation.

### find_integer, and why the earlier galloping attempt failed

`find_integer` (junkdrawer.py:313) scans 1,2,3,4 LINEARLY before going
exponential, because *"it is very hard to win big when the result is
small. If the result is 0 and we try 2 first then we've done twice as
much work as we needed to!"*

The rejected `galloping-attempt-REJECTED.patch` escalated the other way
— full range first, halving down — so whenever only a small step was
accepted it paid ~log(range) failures for it. That is exactly why it
took `bind` from 59 to 984 calls. Right primitive, backwards escalation
order, and applied to the wrong pass. Worth remembering as a unit: the
idea was sound and the implementation was wrong in three separate ways.

"""Harder shrinking benchmarks, to find where tapecheck and Hypothesis
actually differ.

The existing six (shrink_table.ml) were built to expose base_quickcheck's
stock shrinkers, which fail on all of them. Against Hypothesis they are
too easy: both score 100/100 and only cost separates them. These are
chosen to be hard for a Conjecture-class engine, not for a rose tree.

Run Hypothesis first, deliberately: a benchmark Hypothesis also fails is
a poor discriminator, so this establishes which ones are worth the cost
of writing OCaml counterparts.

Each case names the TRUE minimal counterexample, so "fully minimal" is a
real check rather than "did it shrink a bit".

What each is designed to stress:

  duplicate      coordinated deletion -- deleting either duplicate kills
                 the failure, so single-element deletion cannot progress
  unsorted       relative structure -- must keep a descending pair while
                 driving values down
  self_len       long-range dependency: l[0] == len(l). Deleting breaks
                 it, lowering l[0] breaks it; only a simultaneous edit
                 works. This is exactly what tapecheck's
                 lower_and_delete pass exists for.
  load_bearing   the ICSE paper's (0,0) trap: the minimal example hides
                 that one component is load-bearing
  tree_depth     recursive structure
  rare_precond   assume() with ~6/7 rejection -- probes discard handling,
                 where tapecheck measured 2.6x overhead on a 50% filter
  two_lists      coordinated deletion across two independent structures
  big_boundary   integer shrinking at full 64-bit scale
  substring      text shrinking
  nested         nested containers
"""

import sys

from hypothesis import Phase, assume, given, settings, strategies as st
from hypothesis import seed as hyp_seed

TRIALS = 100
CASES = 200


def run_one(strategy, predicate, seed_value):
    calls = [0]
    found = []

    @hyp_seed(seed_value)
    @settings(
        max_examples=CASES, database=None, deadline=None,
        phases=(Phase.generate, Phase.shrink),
    )
    @given(strategy)
    def prop(v):
        calls[0] += 1
        if not predicate(v):
            found.append(v)
            raise AssertionError(repr(v))

    try:
        prop()
        return (False, None, calls[0])
    except AssertionError:
        return (True, found[-1], calls[0])


def has_dup(lst):
    return len(set(lst)) != len(lst)


def is_sorted(lst):
    return all(a <= b for a, b in zip(lst, lst[1:]))


def depth(t):
    if t is None:
        return 0
    return 1 + max(depth(t[0]), depth(t[1]))


trees = st.recursive(st.none(), lambda c: st.tuples(c, c), max_leaves=12)

ROWS = [
    (
        "duplicate: fails iff list has a duplicate",
        st.lists(st.integers(0, 1000)),
        lambda l: not has_dup(l),
        lambda l: l == [0, 0],
    ),
    (
        "unsorted: fails iff list not ascending",
        st.lists(st.integers(0, 1000)),
        is_sorted,
        lambda l: l == [1, 0],
    ),
    (
        "self_len: fails iff l and l[0] == len(l)",
        st.lists(st.integers(0, 50)),
        lambda l: not (l and l[0] == len(l)),
        lambda l: l == [1],
    ),
    (
        "load_bearing: fails iff a == 0 and b >= 5",
        st.tuples(st.integers(0, 1000), st.integers(0, 1000)),
        lambda p: not (p[0] == 0 and p[1] >= 5),
        lambda p: p == (0, 5),
    ),
    (
        "tree_depth: fails iff depth >= 3",
        trees,
        lambda t: depth(t) < 3,
        lambda t: depth(t) == 3,
    ),
    (
        "rare_precond: assume(x % 7 == 3), fails iff x >= 100",
        st.integers(0, 100_000),
        lambda v: v < 100,
        lambda v: v == 101,  # smallest >= 100 with x % 7 == 3
    ),
    (
        "two_lists: fails iff len(xs) == len(ys) >= 2",
        st.tuples(st.lists(st.integers(0, 100)), st.lists(st.integers(0, 100))),
        lambda p: not (len(p[0]) == len(p[1]) >= 2),
        lambda p: p == ([0, 0], [0, 0]),
    ),
    (
        "big_boundary: fails iff x >= 2^62 (full 64-bit range)",
        st.integers(-(2**63), 2**63 - 1),
        lambda v: v < 2**62,
        lambda v: v == 2**62,
    ),
    (
        "substring: fails iff 'ab' in s",
        st.text(alphabet="ab", max_size=40),
        lambda s: "ab" not in s,
        lambda s: s == "ab",
    ),
    (
        "zig-zag: fails iff |m - n| == 1  (their own test_zig_zagging case)",
        st.tuples(st.integers(0, 300), st.integers(0, 300)),
        lambda p: abs(p[0] - p[1]) != 1,
        lambda p: p in ((0, 1), (1, 0)),
    ),
    (
        "nested: fails iff some inner list has length >= 2",
        st.lists(st.lists(st.integers(0, 100))),
        lambda ls: all(len(x) < 2 for x in ls),
        lambda ls: ls == [[0, 0]],
    ),
]


def run_rare_precond(seed_value):
    """assume() cases need their own runner."""
    calls = [0]
    found = []

    @hyp_seed(seed_value)
    @settings(
        max_examples=CASES, database=None, deadline=None,
        phases=(Phase.generate, Phase.shrink),
    )
    @given(st.integers(0, 100_000))
    def prop(v):
        assume(v % 7 == 3)
        calls[0] += 1
        if v >= 100:
            found.append(v)
            raise AssertionError(repr(v))

    try:
        prop()
        return (False, None, calls[0])
    except AssertionError:
        return (True, found[-1], calls[0])


def main():
    for name, strategy, predicate, is_minimal in ROWS:
        found = minimal = total = 0
        worst = None
        for t in range(TRIALS):
            if name.startswith("rare_precond"):
                ok, value, calls = run_rare_precond(t * 1_000_003)
            else:
                ok, value, calls = run_one(strategy, predicate, t * 1_000_003)
            total += calls
            if ok:
                found += 1
                if is_minimal(value):
                    minimal += 1
                elif worst is None:
                    worst = value
        print(
            f"{name}\n"
            f"  hypothesis found {found:3d}/{TRIALS},"
            f" fully minimal {minimal:3d}/{TRIALS},"
            f" avg {total // TRIALS:5d} calls,"
            f" worst: {worst if worst is not None else '-'}"
        )
        sys.stdout.flush()


if __name__ == "__main__":
    main()

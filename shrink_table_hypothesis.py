"""Hypothesis run of demo/shrink_table.ml's six properties.

tapecheck is a port of Hypothesis's Conjecture engine, so Hypothesis is
the reference here, not a rival. Two questions this answers:

  1. How much of the original's shrink quality survived the port?
  2. Are tapecheck's call counts reasonable? 641 and 456 on the two list
     properties looked high, but there was no baseline to judge against.

Same generators, same predicates, same minimality criteria as the OCaml
table, 100 seeds each.

Caveat on the call-count column, stated up front because the numbers are
NOT directly comparable: this counts every invocation of the property,
generation and shrinking together. tapecheck's `attempts` column counts
shrink-phase proposals only. So Hypothesis's number here includes ~the
generation phase that tapecheck's excludes. Compare the minimality
columns confidently; treat the call columns as same-order-of-magnitude
evidence only.
"""

import sys

from hypothesis import Phase, given, settings, strategies as st
from hypothesis import seed as hyp_seed

TRIALS = 100
CASES = 200


def run_one(strategy, predicate, seed_value):
    """Return (found, minimal_value, calls) for one seed."""
    calls = [0]
    found = []

    @hyp_seed(seed_value)
    @settings(
        max_examples=CASES,
        database=None,
        deadline=None,
        # Generation + shrinking only: no database reuse, and no explain
        # phase, since the OCaml table does not run explain either.
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
        # Hypothesis reports the minimal example last.
        return (True, found[-1], calls[0])


ROWS = [
    (
        "int uniform in [0, 1_000_000], fail iff v >= 123_457",
        st.integers(0, 1_000_000),
        lambda v: v < 123_457,
        lambda v: v == 123_457,
    ),
    (
        "pair in [0,1000]^2, fail iff a + b >= 100",
        st.tuples(st.integers(0, 1000), st.integers(0, 1000)),
        lambda p: p[0] + p[1] < 100,
        lambda p: p == (0, 100),
    ),
    (
        "int list, fail iff length >= 3",
        st.lists(st.integers(0, 100)),
        lambda lst: len(lst) < 3,
        lambda lst: lst == [0, 0, 0],
    ),
    (
        "int list, fail iff sum >= 100",
        st.lists(st.integers(0, 1000)),
        lambda lst: sum(lst) < 100,
        lambda lst: lst == [100],
    ),
    (
        "filtered even ints, fail iff v >= 100",
        st.integers(0, 100_000).filter(lambda v: v % 2 == 0),
        lambda v: v < 100,
        lambda v: v == 100,
    ),
    (
        "bind: len in [1,64], list_with_length, fail iff sum >= 100",
        st.integers(1, 64).flatmap(
            lambda n: st.lists(st.integers(0, 1000), min_size=n, max_size=n)
        ),
        lambda lst: sum(lst) < 100,
        lambda lst: lst == [100],
    ),
]


def main():
    for name, strategy, predicate, is_minimal in ROWS:
        found = 0
        minimal = 0
        total_calls = 0
        worst = None
        for t in range(TRIALS):
            ok, value, calls = run_one(strategy, predicate, t * 1_000_003)
            total_calls += calls
            if ok:
                found += 1
                if is_minimal(value):
                    minimal += 1
                elif worst is None:
                    worst = value
        print(f"{name} -- {TRIALS} seeds")
        print(
            f"  hypothesis found {found:3d}/{TRIALS},"
            f" fully minimal {minimal:3d}/{TRIALS},"
            f" avg {total_calls // TRIALS:5d} calls (gen+shrink),"
            f" worst: {worst if worst is not None else '-'}"
        )
        sys.stdout.flush()


if __name__ == "__main__":
    main()

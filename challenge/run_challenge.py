# /// script
# requires-python = ">=3.12"
# dependencies = ["hypothesis==6.164.0", "numpy"]
# ///
"""Shrinking Challenge measurement for current Hypothesis.

Adapted from jlink/shrinking-challenge's own
pbt-libraries/hypothesis/support/run_challenge.py, which is how their
published numbers were produced. Two changes, both forced:

  - HealthCheck.all() was removed; list(HealthCheck) replaces it.
  - Their reports were generated with Hypothesis 5.23.11 in 2020.
    Re-running rather than citing them is the point of this file.

"evaluations" counts test executions from the first interesting example
onward, i.e. the cost of shrinking, which is what tapecheck reports as
`attempts`. Same quantity, so the two are comparable.
"""
import json
import math
import os
import re
import statistics
import sys
from collections import Counter
from random import Random

from hypothesis import HealthCheck, Phase, Verbosity
from hypothesis import seed as with_seed
from hypothesis import settings
from hypothesis.errors import UnsatisfiedAssumption
from hypothesis.internal.reflection import proxies

# Configurable: 100 gives a 95% Wilson interval of about +-4 points even
# at 100/100, and much wider in the middle of the range. Set
# CHALLENGE_RUNS to widen it.
RUNS = int(os.environ.get("CHALLENGE_RUNS", "100"))


def measure(source, filename, expected):
    random = Random(0xC0FFEE)
    compiled = compile(source, filename, "exec")
    results = []
    for _ in range(RUNS):
        seed = random.getrandbits(64)
        namespace = {}
        exec(compiled, namespace)
        test = namespace["test"]
        assert getattr(test, "is_hypothesis_test", False)
        base_function = test.hypothesis.inner_test
        stats = {"seed": seed, "evaluations": 0}

        def record(kwargs, interesting):
            if interesting:
                kwargs = {name: repr(value) for name, value in kwargs.items()}
                if "original" not in stats:
                    stats["original"] = kwargs
                stats["shrunk"] = kwargs
            if "original" in stats:
                stats["evaluations"] += 1

        @proxies(base_function)
        def replacement_function(**kwargs):
            try:
                base_function(**kwargs)
                record(kwargs, False)
            except UnsatisfiedAssumption:
                # A discard is NOT a counterexample. Catching plain
                # Exception here recorded every assume() rejection as
                # interesting, which on an assume-heavy property means
                # the reported "shrunk" value and the evaluation count
                # both describe rejected inputs. calculator is the only
                # challenge here that calls assume.
                record(kwargs, False)
                raise
            except Exception:
                record(kwargs, True)
                raise

        test.hypothesis.inner_test = replacement_function
        test = with_seed(seed)(
            settings(
                database=None,
                suppress_health_check=list(HealthCheck),
                max_examples=10**6,
                phases=[Phase.generate, Phase.shrink],
                verbosity=Verbosity.quiet,
            )(test)
        )
        try:
            test()
        except Exception:
            if "original" not in stats:
                raise
        results.append(stats)

    found = [r for r in results if "shrunk" in r]
    # numpy scalars repr as "np.int16(-1)", so a plain string compare
    # against the challenge's stated answer reports a false 0/100 for
    # bound5 while the values are in fact identical. Normalise rather
    # than record the artefact.
    def norm(s):
        return re.sub(r"np\.\w+\(([^()]*)\)", r"\1", s)

    answers = Counter(
        norm(", ".join(v for v in r["shrunk"].values())) for r in found
    )
    hits = sum(c for a, c in answers.items() if a == expected)
    evals = [r["evaluations"] for r in found]
    print(f"## {filename}\n")
    print(f"  expected      {expected}")
    n = len(found)
    lo_ci, hi_ci = wilson(hits, n)
    pct = 100.0 * hits / n if n else 0.0
    print(f"  normalised    {hits}/{n} runs = {pct:.1f}% "
          f"[95% CI {lo_ci:.1f}-{hi_ci:.1f}] ({len(answers)} distinct)")
    if len(found) < RUNS:
        print(f"  NOT FOUND     {RUNS - len(found)}/{RUNS} runs found nothing")
    if evals:
        print(f"  evaluations   {min(evals)}..{max(evals)} during shrinking, "
              f"mean {statistics.mean(evals):.2f}")
    for a, c in answers.most_common(4):
        mark = "   <- expected" if a == expected else ""
        print(f"      {c:3d} x  {a}{mark}")
    print()
    return (filename, hits, len(found),
            statistics.mean(evals) if evals else 0.0)


def wilson(hits, n):
    """Wilson score interval: sane at 0 and at n, unlike the normal
    approximation, and this suite produces plenty of both."""
    if n == 0:
        return (0.0, 0.0)
    z = 1.96
    p = hits / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, (centre - half) * 100), min(100.0, (centre + half) * 100))


CHALLENGES = {}

CHALLENGES["reverse"] = ("""
import hypothesis.strategies as st
from hypothesis import given

@given(st.lists(st.integers()))
def test(ls):
    assert ls == list(reversed(ls))
""", "[0, 1]")

CHALLENGES["large_union_list"] = ("""
import hypothesis.strategies as st
from hypothesis import given

@given(st.lists(st.lists(st.integers())))
def test(ls):
    all_elements = set()
    for x in ls:
        all_elements.update(x)
    assert len(all_elements) < 5
""", "[[0, 1, -1, 2, -2]]")

CHALLENGES["lengthlist"] = ("""
import hypothesis.strategies as st
from hypothesis import given

@given(st.integers(1, 100).flatmap(
    lambda n: st.lists(st.integers(0, 1000), min_size=n, max_size=n)))
def test(ls):
    assert max(ls) < 900
""", "[900]")

# Not in their Hypothesis set; written to match tapecheck's challenge/.
CHALLENGES["distinct"] = ("""
import hypothesis.strategies as st
from hypothesis import given

@given(st.lists(st.integers()))
def test(ls):
    assert len(set(ls)) < 3
""", "[0, 1, -1]")

for _name, _bad, _exp in [
    ("difference_must_not_be_zero", "d == 0", "10, 10"),
    ("difference_must_not_be_small", "1 <= d <= 4", "10, 6"),
    ("difference_must_not_be_one", "d == 1", "10, 9"),
]:
    CHALLENGES[_name] = (f"""
import hypothesis.strategies as st
from hypothesis import given

@given(st.integers(0, 1000000), st.integers(0, 1000000))
def test(a, b):
    d = abs(a - b)
    assert a < 10 or not ({_bad})
""", _exp)

CHALLENGES["bound5"] = ("""
import warnings
import numpy as np
import hypothesis.extra.numpy as nps
import hypothesis.strategies as st
from hypothesis import given

int16s = nps.from_dtype(np.dtype("int16"))
bounded_lists = st.lists(int16s, max_size=1).filter(lambda x: sum(x) < 256)

@given(st.tuples(bounded_lists, bounded_lists, bounded_lists,
                 bounded_lists, bounded_lists))
def test(p):
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        assert sum([x for sub in p for x in sub], np.int16(0)) < 5 * 256
""", "([], [], [], [-1], [-32768])")

CHALLENGES["calculator"] = ("""
from hypothesis import assume, given, strategies as st

expression = st.deferred(lambda: st.one_of(
    st.integers(),
    st.tuples(st.just('+'), expression, expression),
    st.tuples(st.just('/'), expression, expression),
))

def div_subterms(e):
    if isinstance(e, int):
        return True
    if e[0] == '/' and e[-1] == 0:
        return False
    return div_subterms(e[1]) and div_subterms(e[2])

def evaluate(e):
    if isinstance(e, int):
        return e
    elif e[0] == '+':
        return evaluate(e[1]) + evaluate(e[2])
    else:
        return evaluate(e[1]) // evaluate(e[2])

@given(expression)
def test(e):
    assume(div_subterms(e))
    evaluate(e)
""", "('/', 0, ('+', 0, 0))")


# Three challenges the upstream Hypothesis entry never covered: its
# pbt-libraries/hypothesis/challenges/ has only bound5, calculator,
# large_union_list, lengthlist and reverse. Definitions follow the
# fast-check reference implementations, same as the OCaml port, so the
# two sides are measuring the same property.

CHALLENGES["deletion"] = ("""
from hypothesis import assume, given, strategies as st

@given(st.lists(st.integers()), st.integers(0, 10))
def test(ls, i):
    assume(i < len(ls))
    x = ls[i]
    without = ls[:i] + ls[i + 1:]
    assert x not in without
""", "[0, 0], 0")

CHALLENGES["nestedlists"] = ("""
from hypothesis import given, strategies as st

@given(st.lists(st.lists(st.just(0))))
def test(ls):
    assert sum(map(len, ls)) <= 10
""", "[[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]")

CHALLENGES["coupling"] = ("""
from hypothesis import assume, given, strategies as st

@given(st.lists(st.integers(0, 10)))
def test(ls):
    assume(all(v < len(ls) for v in ls))
    for i, j in enumerate(ls):
        if i != j:
            assert ls[j] != i
""", "[1, 0]")


# binheap: the generation challenge, and the one whose "expected"
# answer is really a tie-break. jqwik and Americium reach the 4-node
# all-non-negative heap below; CsCheck and elm-test stop at 2-node
# heaps containing a negative, which have FEWER nodes but a non-minimal
# value. Recording the upstream string as expected, but the hit rate
# against it should be read as "agrees with jqwik/Americium", not "found
# the minimum".
CHALLENGES["binheap"] = ("""
from hypothesis import given, strategies as st

heap = st.deferred(lambda: st.tuples(
    st.integers(), st.none() | heap, st.none() | heap))

def to_list(h):
    out, stack = [], [h]
    while stack:
        n = stack.pop(0)
        if n is None:
            continue
        out.append(n[0])
        stack = [n[1], n[2]] + stack
    return out

def merge_heaps(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] <= b[0]:
        return (a[0], merge_heaps(a[2], b), a[1])
    return (b[0], merge_heaps(b[2], a), b[1])

def wrong_to_sorted_list(h):
    return [h[0]] + to_list(merge_heaps(h[1], h[2]))

@given(heap)
def test(h):
    l1 = to_list(h)
    l2 = wrong_to_sorted_list(h)
    assert l2 == sorted(l2)
    assert sorted(l1) == l2
""", "(0, None, (0, (0, None, None), (1, None, None)))")


if __name__ == "__main__":
    import hypothesis
    wanted = sys.argv[1:] or list(CHALLENGES)
    print(f"# The Shrinking Challenge, Hypothesis {hypothesis.__version__}\n")
    print(f"{RUNS} runs per challenge.\n")
    rows = [measure(src, name, exp)
            for name, (src, exp) in CHALLENGES.items() if name in wanted]
    print("## Summary\n")
    print("| challenge | normalised | 95% CI | mean evaluations |")
    print("|---|---|---|---|")
    for name, hits, n, mean in rows:
        lo_ci, hi_ci = wilson(hits, n)
        print(f"| {name} | {hits}/{n} | {lo_ci:.1f}-{hi_ci:.1f} | {mean:.1f} |")

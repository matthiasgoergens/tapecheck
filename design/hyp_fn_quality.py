"""Shrink-quality measurement for Hypothesis's functions(), mirroring
tapecheck/proptest's fn-shrink test matrix. Each case runs `find` N
times; the predicate stashes observed behaviour on every satisfying
call, so the stash after `find` returns is the minimal example."""
import sys
from hypothesis import find, settings, strategies as st, HealthCheck

N = 20
S = settings(max_examples=500, database=None,
             suppress_health_check=list(HealthCheck))

def run(name, strategy, predicate_factory, is_minimal):
    exact = found = 0
    for _ in range(N):
        cell = {}
        pred = predicate_factory(cell)
        try:
            find(strategy, pred, settings=S)
        except Exception:
            continue
        found += 1
        if is_minimal(cell):
            exact += 1
    print(f"{name:28s} minimal {exact:2d}/{found:2d} found")

# A. point: f(0) >= 100; minimal has f(0) == 100.
def mk_point(cell):
    def pred(f):
        v = f(0)
        if v >= 100:
            cell["v"] = v
            return True
        return False
    return pred
run("point f(0)>=100",
    st.functions(like=lambda x: ..., returns=st.integers(0, 1000), pure=True),
    mk_point, lambda c: c.get("v") == 100)

# B. sum across two arguments.
def mk_sum2(cell):
    def pred(f):
        s = f(1) + f(2)
        if s >= 100:
            cell["s"] = s
            return True
        return False
    return pred
run("sum f(1)+f(2)>=100",
    st.functions(like=lambda x: ..., returns=st.integers(0, 1000), pure=True),
    mk_sum2, lambda c: c.get("s") == 100)

# C. co-shrink: list + predicate; minimal is ([0], p(0) True).
def mk_co(cell):
    def pred(pair):
        xs, p = pair
        if any(p(x) for x in xs):
            cell["xs"] = list(xs)
            cell["p0"] = p(xs[0]) if len(xs) == 1 else None
            return True
        return False
    return pred
run("co-shrink [x], p(x)",
    st.tuples(st.lists(st.integers(0, 1000), min_size=1, max_size=20),
              st.functions(like=lambda x: ..., returns=st.booleans(), pure=True)),
    mk_co, lambda c: c.get("xs") == [0] and c.get("p0") is True)

# C'. the 1%-cooperation variant that exposed the Rust/OCaml gap.
def mk_co_rare(cell):
    def pred(pair):
        x, f = pair
        v = f(x)
        if v >= 990:
            cell["x"] = x
            cell["v"] = v
            return True
        return False
    return pred
run("rare (x, f x>=990)",
    st.tuples(st.integers(0, 1000),
              st.functions(like=lambda x: ..., returns=st.integers(0, 1000), pure=True)),
    mk_co_rare, lambda c: c.get("x") == 0 and c.get("v") == 990)

# D. call-count stress: sum over a shrinking list; linear positions
# shift as len(xs) changes. Minimal: xs=[0] with f(0)=100.
def mk_sumlist(cell):
    def pred(pair):
        xs, f = pair
        s = sum(f(x) for x in xs)
        if s >= 100:
            cell["xs"] = list(xs)
            cell["vals"] = [f(x) for x in xs]
            return True
        return False
    return pred
run("sum over list >=100",
    st.tuples(st.lists(st.integers(0, 1000), min_size=1, max_size=10),
              st.functions(like=lambda x: ..., returns=st.integers(0, 1000), pure=True)),
    mk_sumlist, lambda c: c.get("xs") == [0] and c.get("vals") == [100])

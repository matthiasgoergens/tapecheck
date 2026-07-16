# Should stream-keyed tapes be backported to Hypothesis? (No.)

Status: assessment, 2026-07-16, measured against hypothesis master
(strategies/_internal/functions.py) with the script below.

## What Hypothesis does

`functions(like, returns, pure=True)` returns a closure that, when
called during the test, draws its result from the LIVE ConjectureData
via `data.draw(returns)`, memoised per argument tuple. The draws land
in the one linear choice sequence, in call order. Outside the test the
function raises InvalidState ("can only be called within the scope of
the @given that created it").

## Measured shrink quality

Twenty `find` runs per case, mirroring our fn-shrink matrix
(test_bq/test_fn_shrink.ml, proptest src/func.rs tests):

    point f(0)>=100              minimal 20/20
    sum f(1)+f(2)>=100           minimal 20/20
    co-shrink [x], p(x)          minimal 20/20
    rare (x, f x>=990)           minimal 20/20   <- stuck 40/40 in OCaml,
                                                    19/60 in Rust, before
                                                    orphan adoption
    sum over list >=100          minimal 20/20   <- call-count stress

Hypothesis is boundary-exact everywhere, including the case that
motivated orphan adoption and the case designed to shift call
positions.

## Why the linear model wins here

Positional identity gives Hypothesis our orphan adoption FOR FREE:
when a shrink edit changes a function argument, the call happens at
the same point in the test, reads the same positions in the linear
sequence, and therefore returns the old argument's value for the new
argument. That is exactly the behaviour-preserving realignment our
keyed engines had to reconstruct explicitly, because their draws
happen outside any linear window (base_quickcheck's split-off states;
proptest values escaping generation). Hypothesis never had the
problem, so a keyed backport has nothing measurable to fix.

A full port would also be architecturally invasive out of proportion
to any gain: the single linear choice sequence is the invariant under
Hypothesis's DataTree (novel-prefix generation), the example database
format, the shrinker pass structure, and the PrimitiveProvider backend
API (crosshair etc. implement per-draw hooks over one stream).

## What the keyed design still buys that Hypothesis lacks

Not shrink quality; a capability: the reported counterexample's
function stays CALLABLE after the run. Hypothesis's minimal function
is dead outside @given by design (they print observed calls via note()
instead). Our engines return a live, pure function backed by the
winning tape: callable in a debugger, in a REPL, in the regression
test the user writes next. That, plus typed cross-run persistence of
per-argument behaviour, is the honest differentiator to present, and
it comes from the same design choice (streams keyed by argument
identity rather than call position) that the shrink-quality argument
turned out not to need.

## Conclusion

Do not port. Reference Hypothesis as the linear-model baseline that
gets the common cases right by construction; position keyed streams
as what you need when draws outlive the engine's linear window, with
the post-run-callable counterexample as the user-visible win.

Measurement script: design/hyp_fn_quality.py, run with
`uv run --with hypothesis python design/hyp_fn_quality.py` (find-based, stashes
observed behaviour on every satisfying predicate call; the stash after
find returns is the minimal example).

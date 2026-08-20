# Multiple failures in one run

> **Status — historical design note, updated 2026-08-20.** Tapecheck no
> longer always stops at the first failure: `Tape_engine.run_multi` and its
> tests in `test_multibug/` and `test_multibug_fn/` have landed. The ordinary
> `run` entry point still reports one failure. The analysis below is retained
> because it explains the origin-preserving design and the capability gap
> that existed when the note was written.

Matthias remembered Hypothesis finding several distinct bugs, and their
root causes, in a single run. It does, and it is a bigger feature than
it first sounds. At the time this note was written, tapecheck stopped at
the first failure.

## How Hypothesis does it

**Failures are keyed by an `interesting_origin`** — a *signature* rather
than a value (`data.py:58`):

```python
InterestingOrigin = Tuple[
    Type[BaseException], str, int, Tuple[Any, ...], Tuple[Tuple[Any, ...], ...]
]
```

Exception type, file, line, plus the same for `__cause__` / `__context__`
chains and PEP-654 exception groups. Their comment (`escalation.py:108`)
is explicit that this exists to see *through* `except:` blocks to the
exception that first raised.

`interesting_examples` is then a **dict keyed by that origin**, not a
single best example. `shrink_interesting_examples` (`engine.py:886`)
shrinks each one separately, and the crucial detail is the predicate:

```python
def predicate(d):
    if d.status < Status.INTERESTING:
        return False
    return d.interesting_origin == target

self.shrink(example, predicate)
```

Shrinking bug A only accepts candidates that still fail *as bug A*.
Without that constraint, shrinking one failure "slips" into a different,
smaller one and you lose the first. The loop

```python
while len(self.shrunk_examples) < len(self.interesting_examples):
```

also picks up origins discovered *during* shrinking, so a bug that only
surfaces while minimising another still gets minimised itself.

There is a setting for the old behaviour: `report_multiple_bugs=False`
shrinks the current minimum and explicitly *allows* slips to any smaller
bug.

## Why the original `run` interface could not do this

`test : 'a -> bool`. A bool has no identity, so there is nothing to key
on: two different bugs are indistinguishable from one bug found twice.

This is the same shape of problem as span tracking (`SPANS-THE-ROOT-CAUSE.md`)
— an interface that discards information the engine would need — but
unlike spans it is *not* forced by the PRNG-level design. It is just a
narrow signature.

## What the port needed

1. **A failure identity.** Either take `test : 'a -> (unit, exn) Result.t`,
   or catch exceptions and derive an origin from the exception plus the
   top non-library frame of its backtrace. OCaml has
   `Printexc.get_raw_backtrace` / `backtrace_slots`, so exception-type +
   file + line is reachable. Note the tests that matter here *raise*
   rather than returning false — the bisimulation and stateful modules
   already work that way, so they would benefit first.
2. **A map from origin to best-so-far**, replacing the single `best`.
3. **An origin-preserving shrink predicate**, which is the part that is
   easy to get wrong: accept a candidate only if it still fails with the
   *same* origin.
4. **A report listing each minimised failure.**

## Interface: a second entry point, not a changed one

Matthias's suggestion, and it dissolves the worst of the cost: keep
`test : 'a -> bool` exactly as it is and add a *differently named*
entry point with the signature multi-bug reporting needs. Nothing
existing changes, and the two can coexist indefinitely.

Sketch:

```ocaml
(* unchanged: one failure, one minimal example *)
val run : ... -> test:('a -> bool) -> 'a result

(* new: the test RAISES to fail, so each failure carries an identity *)
val run_multi :
  ... -> test:('a -> unit) -> 'a multi_result
(* where multi_result carries one minimised example PER distinct origin *)
```

Origin from the exception plus the top non-library frame of
`Printexc.get_raw_backtrace`, which is the OCaml analogue of their
(exception type, file, line) tuple.

Two things this buys beyond compatibility:

- The tests that most want multi-bug reporting already raise. `Bisim`
  and `Stateful` catch exceptions internally today; they would be the
  natural first callers rather than retrofits.
- It keeps the *cheap* path cheap. `run` never needs to build a map or
  compare origins, so nothing in the common case pays for a feature it
  does not use.

Open question in the sketch: whether `run_multi` shares the pass
implementations with `run` (parameterising the passes over "is this
still interesting?") or duplicates the loop. Sharing is obviously right
but is exactly the refactor that gets dearer the longer it waits, since
every pass currently closes over a single `best`.

## Original cost assessment

This was not a pass or a knob; it changed the engine's central loop from
"one best image" to "a map of best images", and it changes the public
`test` signature. That is a bigger change than anything else currently
queued at the time, and it needed doing deliberately rather than at the end
of a long session.

Worth noting the ordering argument, though: it composes badly with later
work if deferred. Every pass currently closes over a single `best`, so
retrofitting a map afterwards touches all of them. If it is going to
happen at all, sooner is cheaper.

## For the email

This is a real capability gap and an honest one to name — Hypothesis
reports N distinct bugs per run, each independently minimised, and we
report one. It also has a nice property as a question: the
origin-preserving predicate is the kind of detail that is obvious in
hindsight and easy to omit, so asking whether there were other
non-obvious pitfalls in getting multi-bug reporting right is a genuine
question rather than a courtesy.

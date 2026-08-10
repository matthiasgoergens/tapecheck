# Independent verification of the head-to-head numbers

The numbers in this directory were produced by a subagent. This is a
separate pass over them, done because they are the project's flagship
claim and therefore the thing most worth attacking.

## 1. Reproduced

Re-run from a clean build under the worktree-local `5.3.0` switch:

```
Scenario 1: queue bisimulation (fair case) -- 300 trials, 200 cases/trial
  tapecheck  found 300/300, exact minimal 300/300, avg ops 3.00, max 3, avg tape proposals 77.3
  qcheck-stm found 300/300, exact minimal 300/300, avg ops 3.00, max 3, avg accepted qcheck shrink steps 13.9

Scenario 2: handle allocator (adversarial) -- 300 trials, 200 cases/trial
  tapecheck  found 300/300, exact minimal 300/300, avg ops 2.00, max 2,  avg tape proposals 76.7
  qcheck-stm found 300/300, exact minimal 232/300, avg ops 2.35, max 12, avg accepted qcheck shrink steps 12.4
```

Matches the reported figures exactly.

## 2. Rival explanation tested and rejected: is qcheck-stm just out of budget?

The obvious way the claim could be dishonest is that tapecheck is simply
given more rope — it spends 76.7 shrink attempts to qcheck-stm's 12.4, a
6x difference. If qcheck-stm were merely being cut off, "232/300" would
be an artefact of the harness rather than a property of the shrinker.

**It is not.** `QCheck2.Test.shrink_` in
`_opam/lib/qcheck-core/QCheck2.ml:1885-1935` recurses on every
successful shrink and terminates only when no candidate fails:

```ocaml
match i' with
| None -> i, r, m, steps
| Some (i_tree',r',m') -> shrink_ st i_tree' r' m' ~steps:(steps + 1)
```

There is no step cap and no budget parameter. QCheck shrinks to a
fixpoint of its own shrinker, so its output is by construction a state
from which it can find no smaller failing candidate. The 12.4 average is
not a limit it hit; it is where its candidate space ran out.

That makes the limitation structural, which is what was claimed:
deleting an earlier `Alloc` leaves a later `Use 1` referring to an index
that no longer exists, the case stops failing, and the deletion is
rejected — so the shrinker cannot get past it however long it runs.

### Measured, not just argued

The above is reasoning from source. Scenario 3 in `head_to_head.ml`
measures it: take the counterexample qcheck-stm settled on, feed it back
through a fresh full shrink pass with its own shrinker, and repeat up to
20 times.

```
Scenario 3: handle allocator, qcheck-stm granted 20 extra full shrink passes
  tapecheck  found 300/300, exact minimal 300/300, avg ops 2.00, max 2,  avg tape proposals 76.7
  qcheck-stm found 300/300, exact minimal 232/300, avg ops 2.35, max 12, avg accepted qcheck shrink steps 12.4
```

Bit-identical to scenario 2. Extra effort buys nothing.

**Harness self-check, because a boosted arm that silently does nothing
produces exactly the same numbers as one that works and finds nothing:**

```
reshrink called 300 times, reproduced the failure 300, fell through 0, changed the case 0
```

So the re-shrink genuinely ran and genuinely re-failed on every trial —
it did not quietly take the `| _ -> (cex, 0)` fallback — and never once
found a smaller failing case. qcheck-stm's output is a true fixpoint of
its shrinker. "It ran out of effort" is dead by both routes.

## 3. Cost is recorded, but the ratio is not meaningful

The old write-up divided 77.3 by 13.9 and called tapecheck 5.5x more
expensive. That compared **all tape proposals** (accepted and rejected)
with qcheck-stm's **accepted shrink steps**. The counters do not measure
the same event, so their ratio is invalid. The harness and output above
now label each unit explicitly. Both arms reach the same three-operation
minimum in scenario 1; this experiment does not yet establish a comparable
CPU, property-call, or proposal-count cost between them.

The quality result in scenario 2 remains valid: tapecheck reaches the
true minimum 300/300 times and qcheck-stm 232/300. The structural
explanation and the repeated-fixpoint experiment above do not rely on
dividing the cost counters.

## 4. Weaker point, recorded rather than fixed

The two arms are described as using "the same seeds". They pass the same
integer to different RNGs (`Tape_engine.run ~seed` vs
`Stdlib.Random.State.make [| seed |]`), so the actual generated
sequences differ. Across 300 trials this is fine for the averages, but
the runs are **not paired**, and the comparison should not be described
as running both engines on identical inputs. A genuinely paired design
would generate sequences once and feed both shrinkers the same starting
counterexample.

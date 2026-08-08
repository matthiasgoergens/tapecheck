# Could tapecheck use the relations library?

> **Nudge: candidate 1 is ready to go, and the one open decision turned out
> not to be a decision.** The rewrite below is verified equivalent,
> asymptotically better, and about ten lines. The dependency direction has
> already been shown to work, since `rel` is installable and `base`-only, so
> tapecheck can consume it with no vendoring and no `base_quickcheck`
> collision.
>
> **The pair-ordering caveat was wrong and is withdrawn** (issue #14). It
> claimed the relational form yields candidates sorted rather than in position
> order, so a given seed would select a different mutation. Both halves of
> that check out false: the loop prepends `(i, j)` scanning `i` outermost and
> ends with `List.rev`, so it already emits ascending lexicographic order; and
> `rel`'s `to_list` is documented "Sorted, so it is a canonical form" under
> structural comparison, which on `int * int` *is* lexicographic. The two
> orders coincide. Nothing needs sorting back.

A survey, prompted by the observation that the tell-tale sign is **wanting to
look data up by more than one key**. tapecheck has that in two places, and both
are visible in the source as the workaround rather than the intent: an array
keyed by *position*, an algorithm that wants it keyed by something else, and
therefore either a quadratic scan or a hand-rolled secondary index.

Relations library: [binary-relations](https://github.com/matthiasgoergens/binary-relations).

## Candidate 1 — `correlate_image` (`engine/tape_engine.ml`)

The choice array is keyed by position. The correlated-value mutation wants to
find every pair of choices **sharing bounds**, i.e. to look the same data up by
bounds. With no such key available it scans all ordered pairs:

```ocaml
for i = 0 to n - 1 do
  for j = 0 to n - 1 do
    if i <> j then
      match arr.(i), arr.(j) with
      | Integer a, Integer b
        when a.lo = b.lo && a.hi = b.hi && a.value <> b.value -> pairs := (i,j) :: !pairs
      | _ -> ()
  done
done
```

Two choices share bounds exactly when they are related by `bounds >> bounds°`,
and share a value exactly when related by `values >> values°`. What the loop
computes is the first minus the second — and subtracting the second removes the
diagonal for free, since a choice always shares its own value:

```ocaml
Relation.diff
  (Relation.compose bounds (Relation.converse bounds))
  (Relation.compose values (Relation.converse values))
```

**Verified equivalent**, and the driver is in the repo rather than described:
`test_relations/`, run by `dune test`. It property-tests with tapecheck itself
over randomly generated choice lists (6863 cases, 2462 of them with a
non-empty candidate set — the generator draws bounds from a three-element pool
precisely so that sharing is common rather than rare) and then goes exhaustive
over every shape with n ≤ 4 from two values and two bound pairs.

It asserts LIST equality, not set equality, because `correlate_image` selects
with `pick mod length` and indexes the result — so the order is part of the
contract, and that assertion is what settles the withdrawn caveat above.

Both halves are kill-tested, since a verification driver that cannot fail is
worth nothing: dropping the `diff` makes the diagonal reappear and the test
fails with `loop= rel=(0,0)`; reversing the relational order fails with
`loop=(0,1) (1,0) rel=(1,0) (0,1)`.

The previous version of this line claimed the same result "property-tested
with tapecheck itself at `4b9a619` ... (Driver notes below.)" — with no driver
notes below and no relation test anywhere in the repo. The result was right;
the evidence for it did not exist.

**The performance is a footnote at tape sizes.** For the record the loop is
Θ(n²) and the relational form groups through an index — 2 800 tuples against
160 000 comparisons on 400 choices with distinct bounds — but a tape has tens
of choices, not thousands, so the honest claim is only that nothing regresses.

**The version I would actually propose** writes the diagonal removal where a
reader can see it, rather than letting it fall out of subtracting
`shares_value`:

```ocaml
let shares_bounds = Relation.compose bounds (Relation.converse bounds) in
let shares_value  = Relation.compose values (Relation.converse values) in
let self          = Relation.identity_on (Relation.dom bounds) in
Relation.diff (Relation.diff shares_bounds self) shares_value
```

One `diff` longer than the clever form, and it maps one-for-one onto the
loop's three conditions — `i <> j`, equal bounds, differing values — which is
what makes it reviewable against the original.

**The argument is how it reads, and it cuts both ways.** In favour: the two
conditions get names, `same_bounds` and `same_value`, and the loop's three-part
`when` guard disappears along with the index bookkeeping. Against, and worth
saying out loud: the relational form drops the diagonal *implicitly* — it falls
out of subtracting `same_value`, since a choice always shares its own value —
where the loop says `if i <> j` in plain sight. That is cleverness, and a
reviewer has to stop and check it. If the intent is to be obviously correct
rather than merely correct, writing the diagonal removal explicitly is the
better trade even though it is longer.

**A migration caveat that dissolved on inspection.** `pick` selects among the
candidate pairs by index, so the *order* of the list is genuinely part of the
observable behaviour — that much stands, and it is why `test_relations`
asserts list rather than set equality. What does not stand is the conclusion
drawn from it. This section used to say the loop yields pairs "in position
order" against the relational form's "sorted as a set", and therefore that a
given seed would select a different mutation and recorded regressions would be
invalidated.

The two orders are the same. The loop prepends `(i, j)` with `i` outermost and
finishes with `List.rev`, so what comes out is ascending lexicographic —
"position order" and "sorted" are the same thing here. `rel`'s `to_list` is
documented "Sorted, so it is a canonical form" under structural comparison,
and structural comparison on `int * int` is lexicographic. No re-sorting, no
invalidated regressions, no behaviour change.

Worth noting how the error was made, since it is a cheap one to repeat: the
loop *looks* like it emits position order because the nested loops are written
in position order, and the `List.rev` that makes the claim true is on a
different line from the `::` that makes it false. Neither this document nor
the issue that questioned it settled the matter by reading `rel`; the test did.

## Candidate 2 — signature grouping in the shrink loop (`engine/tape_engine.ml`)

```ocaml
let groups = Hashtbl.create (module String) in
while !i + !k <= n do
  Hashtbl.add_multi groups ~key:(signature arr !i !k) ~data:!i;
  Int.incr i
done;
Hashtbl.iteri groups ~f:(fun ~key:_ ~data:positions -> ...)
```

This is the pattern stated outright: the array is keyed by position, the pass
needs it keyed by signature, so it **builds a secondary index by hand** and
then has to undo an artefact of the tool (`add_multi` prepends, so the code
reverses to restore ascending order).

As a relation `position → signature`, the grouping is `group (converse sig)`,
and the ordering artefact disappears because the library's `group` returns each
image already sorted. This is a smaller win than candidate 1 — the Hashtbl is
not asymptotically wrong, just hand-rolled — but it is the clearest illustration
of the tell: *if you are writing `Hashtbl.add_multi` to invert something, you
are building an index because your data structure only has one key.*

## Not candidates

- `tape/tape.ml`'s `streams` and `splits` are two tables under the *same* key,
  which is one relation with two columns rather than a multi-key problem.
- `tape_explain.ml`'s `positions_of` looks like a relation — it flattens an
  image into `(seg, key, idx, choice)` — but it has a single call site that
  makes one pass. No second key is wanted, so nothing is gained.

## Does the dependency direction actually work?

This was the question worth answering, since tapecheck would depend on the
relations library while that library's own tests depend on tapecheck. Tried,
and it works:

- `rel` was installed into a switch; a probe inside a tapecheck worktree
  declared `(libraries rel tape_engine base_quickcheck base stdio)`, built, and
  ran.
- **No library cycle exists**: `rel` → `base`; `tape_engine` → `rel` + its
  vendored `base_quickcheck`; the relations library's law tests → `rel` +
  `tape_engine`. Dune is content, because the cycle is only between *packages*,
  not between libraries.
- **No `base_quickcheck` collision**, which is the thing that would normally
  kill this: tapecheck vendors its own, and `rel` depends on `base` and
  `sexplib0` and nothing else. That is a direct dividend of `rel` having been
  moved off `Core` — had it still pulled `Core`, the installed
  `base_quickcheck` would have arrived transitively and clashed with the
  vendored one, which is exactly what blocks the relations library's
  `tapecheck-shrinking` branch from being merged today.

The remaining obstacle is **opam, not dune**: a `with-test` dependency from
`rel` on `tape` plus a real dependency from `tape` on `rel` is a cycle for the
solver. The conventional fix is to split the tapecheck-driven tests into their
own package, which costs an opam file and nothing else.

## On testing tapecheck with tapecheck

Worth stating explicitly, since it is easy to get wrong. The verification above
is legitimate because **the driver is not the code under test**: the property
compares two copies of the *mutation logic*, and tapecheck is only the
generator and shrinker around it. If the engine's own internals were rewritten
with relations, the driver would have to be a **pinned, known-good** tapecheck
rather than the working tree — otherwise a bug in the rewrite could mask itself
by breaking the very search that would find it. The probe above pins `4b9a619`
for that reason.

## Verdict

Candidate 1 is worth doing, but for readability rather than speed: at tape
sizes the performance only has to stay competitive, and it does. The
pair-ordering caveat has been settled — the orders coincide, so there is
nothing to handle — and the implicit diagonal removal should probably be made
explicit: being *obviously* right matters more here than being short, and it
is the one place where the kill test had to tell me what the code was doing
rather than the code telling me.

Candidate 2 is illustration more than optimisation. Both are the same finding:
*tapecheck stores tapes in arrays keyed by position, and two of its passes want
a different key.*

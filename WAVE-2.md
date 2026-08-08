# Wave 2: what becomes possible if we may change the libraries below us

Written 2026-08-09, after `HYPOTHESIS-GAPS.md` measured the gaps and
attributed most of the big ones to a constraint that turns out not to be
a constraint.

## The premise, restated

The README says the vendored `base_quickcheck` compiles against the shim
unmodified, and calls that the entire integration. Every structural gap
in `HYPOTHESIS-GAPS.md` traces back to it: recording sits at the PRNG
layer, so the tape sees `int64`/`float`/`bool` draws and nothing about
the structure that produced them.

That property is an **adoption stance for the first wave**, not a design
axiom. It exists so the work can be put in front of Jane Street
maintainers as "your library, unchanged, plus a recording seam". Once
that conversation has happened, a second wave may change
`splittable_random` and `base_quickcheck` themselves.

Worth noting that wave 2 has already started without being called that:
`proposals/base_quickcheck-non_uniform.patch` is exactly such a change,
and it is measured. With it applied *and* `sort_siblings` enabled,
`distinct` goes from 0/1000 to 649/1000.

## What the constraint was actually blocking, ranked

**1. Spans.** The top-ranked gap, and the one that blocks four separate
shrink passes: `pass_to_descendant`, `remove_discarded`, a true
`reorder_spans`, and `minimize_duplicated_choices`. `test_poison` prices
their absence at 12/34 against Hypothesis's 34/34, and
`test_poison_lists` at 21/48 against 48/48.

**2. First-class string and bytes choices.** Hypothesis draws five
choice types; we record three. Strings arrive as a length integer
followed by N integers carrying character bounds, so there is nothing
for a string-aware pass to grip. This is the shape of the failing
"list of strings shrinks to 10 empty strings" case.

**3. Shipping `sort_siblings`.** Needs only the `non_uniform` patch,
which is already written and verified to apply.

## The mechanism for spans, and why it is smaller than it sounds

The seam already exists and already carries structural callbacks.
`vendor/sr_real/sr_real.ml` has:

```ocaml
and intercept =
  { int64 : ...
  ; float : ...
  ; unit_float : ...
  ; bool : ...
  ; on_split : unit -> intercept option
  ; on_perturb : int -> intercept option
  }
```

`on_split` and `on_perturb` are already structural events rather than
value draws. Two more of the same shape:

```ocaml
  ; on_span_start : span_label -> unit
  ; on_span_stop : unit -> unit
```

The generator side is a bracket, and every combinator that needs one
already has `random` in scope. `base_quickcheck`'s `bind` today:

```ocaml
let bind t ~f =
  create (fun ~size ~random ->
    let x = generate t ~size ~random in
    generate (f x) ~size ~random)
```

and with the bracket:

```ocaml
let bind t ~f =
  create (fun ~size ~random ->
    Splittable_random.span_start random Label.bind;
    let x = generate t ~size ~random in
    let y = generate (f x) ~size ~random in
    Splittable_random.span_stop random;
    y)
```

The combinators that need it are roughly `bind`, `map`, `both`,
`list_generic`, `union`/`weighted_union`, `fixed_point`, plus whatever
`ppx_quickcheck` generates for records and variants. That is a bounded
list, not a rewrite.

**The number that decides whether this is upstreamable**: with the hooks
defaulting to no-ops, a non-tape user pays two function calls per
combinator invocation and nothing else. That cost has to be measured
before proposing it, because it is the first thing a maintainer will
ask, and if two no-op calls per `bind` are measurable then the approach
needs rethinking before a single pass gets written. Measure it first —
it is the cheapest possible experiment and it gates everything else.

## Where OCaml's type system genuinely helps: span labels

Hypothesis labels spans with integers derived from strategy identity —
effectively a hash. That is opaque when reading a trace and collides
silently.

OCaml has a better option that Python does not, and it is **extensible
variants**, not GADTs:

```ocaml
type span_label = ..
type span_label += Bind
type span_label += List_element of int
type span_label += Union_branch of int
```

Buys: a downstream library can add its own labels without touching the
core type; labels are nominal, so two libraries cannot collide by
accident the way hashes or polymorphic variants can; and matching on the
labels you know about still works, with a catch-all for the rest.

Costs: extensible variants have no structural serialisation, so the wire
format needs a registry mapping label to a stable tag. That registry is
a feature rather than a tax — it makes tape files self-describing, and
the format is explicitly versioned already (`ct1`, `ct2`).

## What does not change

- **Not GADTs for the choice type.** The tape is a heterogeneous array
  that gets serialised, so it is dynamically typed at rest by necessity.
  A GADT needs an existential wrapper to live in that array, which puts
  every shrink pass straight back to matching on a variant. Cosmetic.
- **Not polymorphic variants for choices.** They would forfeit
  exhaustiveness, which is the main asset here — adding a constructor to
  `Tape.choice` is a compile error at every match site, so widening the
  IR is mechanical and the compiler enumerates the work. Hypothesis had
  to hunt `isinstance` checks by hand.
- **Not `Marshal` for the wire format.** Tapes get pasted between
  versions and machines; the format stays explicit and versioned.

## A cheaper win that needs no wave-2 change at all — SUPERSEDED, the premise is false

**Measured and withdrawn, 2026-08-09.** The idea below assumed a string
appears on the tape as a run of *consecutive* integers sharing character
bounds. It does not. Dumping the tape for a 30-element list of short
strings gives 206 choices of which only 13 are character draws; the rest
is `[0,0]`/`[1,1]`/`[0,1]` bookkeeping plus a Fisher-Yates permutation
loop that emits one draw per element ahead of any content. Character
draws are interleaved with that, not contiguous.

Chasing it also produced the better finding: the failing "list of
strings" case is not about strings at all — its outer list length never
comes down, because `sizes` redistributes freed length into the
surviving elements. See the reproducer, and the fix on
`wave2/monotone-list-sizes`.

The paragraph is kept rather than deleted because the *reasoning* about
where inference could work is still worth having if spans ever land, and
because a design note that quietly loses its wrong turns is less useful
than one that records them.

Strings are already *inferable* from the existing tape.
`char_uniform_inclusive lo hi` is `Splittable_random.int ~lo:(Char.to_int
lo) ~hi:(Char.to_int hi)`, and `string_of` is a length draw followed by
that repeated. So a string on the tape is a run of consecutive integers
sharing character bounds — a signature that `sort_siblings` already
computes for a different purpose.

A string-aware pass over inferred runs needs no IR change, no wire
change, and no library change. It is strictly weaker than a real
`String` choice (the inference can be fooled by a genuine list of small
integers), but it is available now and it targets a measured failure.
Worth doing first, if only to find out how much of the string gap is
reachable without wave 2.

## Sequencing

1. Measure the no-op hook cost. Gate everything on it.
2. File the `non_uniform` patch (already written, already verified).
3. Inferred-string pass, as the cheap probe of how much §2 is worth.
4. Span hooks in `splittable_random` + `base_quickcheck`.
5. The four span-dependent passes, one at a time.

Every step has an existing scoreboard: the challenge suite at n=1000,
`test_poison`, `test_poison_lists`, `test_shrink_quality`, and the
regression guard. None of this needs a new way to tell whether it
worked.

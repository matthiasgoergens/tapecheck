# base_quickcheck's edge-case shortcut defeats tape shrinking

A proposed change to `base_quickcheck`'s `Generator.non_uniform`. It is
distribution-preserving, measured, and it moves the Shrinking Challenge
`reverse` benchmark from 0/100 to 50/100.

## The symptom

Implementing the [Shrinking Challenge](https://github.com/jlink/shrinking-challenge)
in tapecheck (`challenge/`), every list-of-integers challenge came back
littered with `4611686018427387903` — OCaml's `max_int` — where every
other library in the suite reports `1`:

```
## reverse
  expected      [0, 1]
  normalised    0/100 runs (10 distinct answers)
       45 x  [0, 4611686018427387903]
       16 x  [0, -1]
       15 x  [-1, 0]
        8 x  [4611686018427387903, 0]
```

The shrinker had *converged*: `converged = true`, a full round of every
pass finding nothing smaller. So it was not giving up. By its own order,
`max_int` genuinely is smaller than `1`.

## Why

`Generator.int` is

```ocaml
let all =
  [%map
    let negative = bool
    and magnitude = log_inclusive Integer.zero Integer.max_value in
    if negative then Integer.bit_not magnitude else magnitude]
```

and `log_inclusive = non_uniform log_uniform_inclusive`, which is

```ocaml
let non_uniform f lo hi =
  weighted_union [ 0.05, return lo; 0.05, return hi; 0.9, f lo hi ]
```

`weighted_union` draws **one float** and binary-searches the cumulative
weights. `return lo` and `return hi` then draw **nothing further**,
while `f lo hi` draws two more choices. So on the tape:

| value | recorded choices | length |
|---|---|---|
| `0` | `Bool false; Float 0.00` | 2 |
| `max_int` | `Bool false; Float 0.05` | 2 |
| `1` | `Bool false; Float 0.5; Int exp; Int mantissa` | 4 |

Shortlex is length-first. A 2-entry tape beats a 4-entry tape whatever
the entries are, so `max_int` outranks `1` and no shrink pass can move
off it. The extreme values are the *cheapest to encode*, which is
exactly backwards from what a shrinker wants.

This is not specific to tapecheck. It applies to any shrinker ordering
`base_quickcheck` generators by their recorded choice sequence.

## What does not work

Reordering the branches to `[0.05, return lo; 0.9, f lo hi; 0.05, return hi]`
so that `hi` is reached only by a *large* selector float. Measured: no
effect (`reverse` stayed at 0/100). Length dominates the comparison, so
the selector value is never reached as a tiebreak. Worth recording
because it is the obvious first move and it is wrong.

## What works

Draw the selector **first**, always draw the general value, and order
the branches lo / general / hi:

```ocaml
let non_uniform f lo hi =
  let general = f lo hi in
  let selector =
    create (fun ~size:_ ~random -> Splittable_random.float random ~lo:0. ~hi:1.)
  in
  bind selector ~f:(fun p ->
    map general ~f:(fun v ->
      if Float.( < ) p 0.05 then lo else if Float.( < ) p 0.95 then v else hi))
```

`f lo hi` is hoisted out of the continuation deliberately: building a
generator is pure, so the recorded draws are identical either way
(verified -- the distribution table and every challenge number below are
unchanged by the hoist), but it keeps the closure capturing a value
rather than the function, which matters on the mode-annotated branch.

Both properties are needed, and neither alone suffices:

1. **Equal length.** Every path now draws the selector and `f lo hi`, so
   the shortcut branches no longer win on length.
2. **Selector first, `hi` last.** With lengths equal, position 0
   decides, and the selector orders the outcomes `lo < general < hi` —
   which is `0 < 1 < max_int`, the intended order.

Cost to a non-tape user: `f lo hi` is always evaluated, so two extra
PRNG calls in the 10% of draws that take a shortcut.

## Measured

Distribution, 400 000 draws of `Generator.int` each
(`diag2/probe_dist.ml`):

| | stock | proposed |
|---|---|---|
| magnitude = 0 | 6.415% | 6.452% |
| magnitude = max_value | 5.016% | 5.013% |
| other | 88.570% | 88.534% |
| negative | 50.023% | 50.051% |

Magnitude bit-length histogram over 63 buckets: chi-square 36.5 on 63
degrees of freedom. Statistically indistinguishable, as intended — the
selector is independent of the value, so the change is a pure
reassociation.

Shrink quality, Shrinking Challenge, 100 runs each:

| challenge | stock | proposed |
|---|---|---|
| reverse | 0/100 (10 distinct answers) | **50/100** (6 distinct) |
| distinct | 0/100 | **12/100** |
| large_union_list | 0/100, mean 1318 evals | 0/100, mean **1257** evals |
| lengthlist | 64/100 | 64/100 (unaffected) |
| difference (×3) | unchanged | unchanged (uses `int_uniform_inclusive`) |

`max_int` disappears from the `reverse` and `distinct` answers entirely,
and cost goes down on all three.

**But it is not a free win, and the full row set says so.** Measured
afterwards, `calculator` is unchanged in quality at slightly lower cost
(3/100, 880.5 to 839.6) and **`bound5` LOSES**: 17/100 to 7/100. Net
normalisation across the suite is well positive -- 62 positions gained
against 10 lost -- but this has to be stated plainly rather than
buried, and it is why the two rows are no longer "—" in CHALLENGE.md.

Not diagnosed. `bound5` is the one challenge whose expected answer
contains both an extreme (`-32768`, reached by the `lo` branch) and a
small value (`-1`, which must come from the general branch), so it is
plausibly sensitive to precisely what the reordering changes.

## What is still wrong after it

`reverse` reaches 50/100, not 100/100. The remainder is a second, milder
instance of the same kind of thing: `if negative then bit_not magnitude`
means `-1` is `bit_not 0`, so `-1` has magnitude 0 while `1` has
magnitude 1. `-1` is therefore strictly cheaper to encode than `1`, and
the leftover answers are `[0, -1]` and `[-1, 0]`. Hypothesis orders
integers `0, 1, -1, 2, -2`, which is the order a reader expects.

Not proposing a change for that one: unlike the `non_uniform` case it
would alter which values are cheap in a way that is more visibly a
design choice than a bug, and the payoff is smaller. Recorded so it is
not rediscovered from scratch.

## Two patches, because upstream keeps two lineages

`base_quickcheck` does not use conditional compilation to span stock
OCaml and OxCaml. `master` and the `oxcaml` branch carry the same
mode-annotated source (their `non_uniform` is byte-identical); the stock
releases are separate branches. `src/generator.ml` differs by 783 lines
between `master` and `v0.17`.

So there are two patches:

- `base_quickcheck-non_uniform-OXCAML.patch` — against `master`, using
  `(create [@mode portable])`, `(bind [@mode portable])` and
  `(map [@mode portable])` to match the surrounding style. **This is the
  one to offer**, since it is the live development lineage.
- `base_quickcheck-non_uniform.patch` — the same change without mode
  annotations, against the stock lineage, which is what tapecheck
  vendors.

### Verification status, stated exactly

- **Stock variant: compiled.** Applied to a clean checkout of upstream
  `v0.17.1` and built with OCaml 5.3.0 — `dune build src/` clean,
  `base_quickcheck__Generator.cmi` produced.
- **OxCaml variant: NOT compiled.** `master` requires a newer OxCaml
  than the public `5.2.0+ox` opam overlay publishes — the overlay has
  `v0.18~preview.130.91+190`, `master` is `.100+614`, and `oxcaml` is
  `.106+341`. Building `src/` there fails in `with_basic_types.ml`
  (`or_null` kinds), `shrinker.ml` (contended/uncontended) and
  `generator.mli` (`value_or_null mod maybe_null`) — all pre-existing,
  none from this change, but they mean the change cannot be
  compile-checked locally. An early "the error set is unchanged" reading
  was weak evidence: dune was stopping before reaching most of them.

That gap is the same one described in
[splittable_random#2](https://github.com/janestreet/splittable_random/pull/2):
the public overlay lags the mirror. It should be said plainly in any PR
rather than implied away.

Neither patch is applied to `vendor/`, which stays byte-identical to
upstream so that vendoring remains a pure name-resolution device.

Offering either upstream is an outward-facing action and is not done.

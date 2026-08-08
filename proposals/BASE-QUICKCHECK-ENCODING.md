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

**The full row set adds two more, and one needs explaining.**
`calculator` is unchanged in quality at slightly lower cost (3/100,
880.5 to 839.6). `bound5` moves 17/100 to 7/100 — which looks like a
regression and is not one.

Measured directly over 1000 runs: on `bound5`, **all 1000 reduce to
exactly two elements and 998 to the right content** either way — two
singleton lists holding `-1` and `-32768`, three empties. The challenge
scores one exact permutation, so the score measures which of the five
symmetric slots the singletons land in, not the quality of the
reduction. The patch shifts the preferred permutation from
`([], [], [], [-1], [-32768])` to `([], [], [], [-32768], [-1])`. Both
are equally minimal.

At 1000 runs the shift is unambiguous rather than marginal: stock
159/1000 (95% CI 13.7-18.3) against 52/1000 (4.0-6.8), non-overlapping.
At 100 runs it was about two sigma and should not have been reported as
settled. The answer breakdown confirms the mechanism directly -- all
four most common patched answers place `-32768` before `-1`, which is
what a minimal lo-branch selector sorting ahead of the value produces.

The mechanism is worth recording, because it is this change's own
pathology relocated. The selector is recorded BEFORE the value, so
whichever branch the smallest selector reaches sorts ahead of every
other outcome however small its value. Ordering `lo` first is correct
when `lo` IS the shrink target — true for `int`'s magnitude,
`log_inclusive zero max_value`. For a range straddling zero like int16's
`[-32768, 32767]`, `lo` is an extreme, so `-32768` sorts ahead of `-1`.

**Ordering the branches by distance from the target instead fixes that
and makes normalisation worse.** Tried: general branch first when the
range straddles zero. Value ordering becomes correct, cost falls 30%
(268 to 188 evaluations) -- and distinct answers go from 17 to 87,
because removing the strong `lo`-first preference leaves many slot
configurations tied. Not adopted. Recorded so it is not re-attempted.

The residue is positional: canonicalising which slot holds what means
moving content between positions, i.e. `reorder_spans`, which needs
spans.

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
releases are separate branches. `src/generator.ml` differs by 783
changed lines between `master` and `v0.17` — 502 added and 281 removed,
per `git diff --numstat v0.17 master -- src/generator.ml`, with `master`
at 1a5d1f5 (`v0.18~preview.130.100+614`, 2026-05-15). Pinning the SHA
because `master` moves and the figure otherwise decays. Stating the
metric because it is easy to measure something adjacent and conclude the
figure is stale: adding `src/generator.mli` to the same command gives
999, and the raw `git diff` output is 1136 lines.

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
  `base_quickcheck__Generator.cmi` produced. Re-checked after the
  `let general` hoist (issue #13): the patch applies to
  `vendor/base_quickcheck/generator.ml` — the same stock source — and
  `dune build vendor/` is clean.
- **Both patches: application re-checked, 2026-08-08.** `patch
  --dry-run` succeeds for the stock patch against the vendored
  generator and for the OxCaml patch against upstream `master` at
  `1a5d1f5`. Worth stating separately from "compiles", because an
  edited patch can stop applying while the code it describes is still
  fine.
- **OxCaml variant: NOT compiled, and it cannot be from outside.** This
  was chased properly rather than assumed, and the conclusion is a
  pincer:

  - With the **`5.2.0+ox`** switch, the compiler is too old for master's
    source. `src/` fails in `with_basic_types.ml` (`or_null` kinds),
    `shrinker.ml` (contended/uncontended) and `generator.mli`
    (`value_or_null mod maybe_null`) — all pre-existing, none from this
    change. It is not a question of master having moved ahead: checking
    out `e20523d`, master at *exactly* the version the overlay ships
    (`.91+190`), fails identically. The compiler is the limit, not the
    source.
  - So I built a **`5.4.0+ox`** switch. The compiler works. But the ox
    overlay's *library set* is built for 5.2: `ppxlib_jane` resolves to
    `.91+190`, which requires `ppxlib_ast`, which caps at
    `ocaml < 5.3.0`. base_quickcheck's dependencies therefore cannot be
    installed alongside a 5.4 compiler at all.
    (`oxcaml-compiler.5.4.0-ox2` is separately broken — its
    `ignore-opam.patch` does not apply to the tarball it fetches;
    `5.4.0-ox1` builds.)

  There is no configuration of the public OxCaml overlay that both
  compiles master's source and can install its dependencies. Logs in
  `../tapecheck-notes/ox-*.log`.

  An early "the error set is unchanged before and after my change"
  reading was weak evidence and should not have been offered: dune was
  stopping before it reached most of the errors, and the file I assumed
  depended on `Generator` (`with_basic_types.ml`) is a pure signature
  file that does not.

That gap is the same one described in
[splittable_random#2](https://github.com/janestreet/splittable_random/pull/2):
the public overlay lags the mirror. It should be said plainly in any PR
rather than implied away.

Neither patch is applied to `vendor/`, which stays byte-identical to
upstream so that vendoring remains a pure name-resolution device.

Offering either upstream is an outward-facing action and is not done.

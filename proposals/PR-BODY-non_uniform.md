# PR body, ready to file against janestreet/base_quickcheck

Title: `Generator.non_uniform: make the edge-case shortcut shrink-friendly (distribution unchanged)`

Not yet filed. Intended to go up immediately before the email, so the
two can reference each other.

---

**Up front, because it decides whether the rest is worth your time:**
this change helps only shrinkers that order candidates by the recorded
choice sequence. That is not `base_quickcheck`'s model —
`Shrinker.t` works on values, not draws — so on `base_quickcheck`'s own
terms this is a small cost for no benefit. I am filing it because the
cost is genuinely small and the benefit to anything replay-based is
large, but a "no" is a perfectly reasonable answer and I will not be
offended by it.

## What

`Generator.non_uniform` is currently

```ocaml
let non_uniform f lo hi =
  weighted_union [ 0.05, return lo; 0.05, return hi; 0.9, f lo hi ]
```

`weighted_union` draws **one float** and binary-searches the cumulative
weights, after which `return lo` and `return hi` draw *nothing further*
while `f lo hi` draws two more choices.

The consequence is that `Generator.int` reaches `max_int` through a
two-draw path and `1` through a four-draw path. Any tool that records
draws and orders candidates shortlex — length first — therefore ranks
`max_int` *below* `1`. The extreme values become the cheapest things to
encode, which is backwards from what a reducer wants.

Concretely, shrinking `lists(int)` against `List.rev l = l` converges
(genuinely converges — every pass exhausted, nothing smaller available)
on `[0, 4611686018427387903]` where every other library in the
[Shrinking Challenge](https://github.com/jlink/shrinking-challenge)
reports `[0, 1]`.

## The change

Draw the selector first, always draw the general value, and order the
branches lo / general / hi:

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

`general` is bound outside the `bind` deliberately: `f lo hi` is a
generator, and building it once when `non_uniform` is applied rather
than once per draw is what keeps the claim about allocation below true.

Both properties are needed and neither alone suffices:

1. **Equal draw count on every path**, so the shortcut branches no
   longer win on length.
2. **Selector drawn first, `hi` last**, so that once lengths tie,
   position 0 decides — and the order it imposes is `lo < general < hi`.

I mention the second because the obvious minimal fix — just reordering
the `weighted_union` list so `hi` needs a large selector float — does
**not** work, and I measured that rather than assuming it. Length is
compared before the selector ever is.

## Distribution is unchanged

Not "by construction" — counted. `unit_float` returns `k / 2^53` for
`k` in `[0, 2^53)`, so the selector has a known finite grid and the
branch split can just be enumerated exactly. Both formulations give:

| branch | selectors | |
|---|---|---|
| `lo` | 450359962737050 | |
| `hi` | 450359962737050 | |
| general | 8106479329266892 | |

The same three numbers either way. (Neither is exactly 5/5/90: `0.05`
as a binary64 is a shade over, so the true split is 0.0500000000000000444
/ 0.0500000000000000444 / 0.8999999999999999. Stock is wrong by the
identical amount, since it is the same constant.)

What *does* change is which selector reaches which branch, and on whole
intervals rather than at the boundaries: stock's cumulative weights are
`[0.05; 0.10; 1.0]`, so `hi` occupies `(0.05, 0.10]`, where after the
change it occupies `[0.95, 1)`. That remapping is the point of the
change rather than a side effect — it is exactly what lets position 0
impose `lo < general < hi`. I mention it because it is visible to
anything that *forces* a selector rather than sampling one: a forced
`1.0` lands on general before and `hi` after. `unit_float` never
returns `1.0`, so nothing in `base_quickcheck` can see this; a
replay-based harness that pins float draws can.

Also verified empirically, over 400 000 draws of `Generator.int`:

| | before | after |
|---|---|---|
| magnitude = 0 | 6.415% | 6.452% |
| magnitude = `max_value` | 5.016% | 5.013% |
| neither | 88.570% | 88.534% |
| negative | 50.023% | 50.051% |

Magnitude bit-length histogram over 63 buckets: chi-square 36.5 on 63
degrees of freedom. Statistically indistinguishable.

## Cost

`f lo hi` is now always generated from, so the 10% of draws that
previously took a shortcut pay two extra PRNG calls. The generator
itself is still built once per `non_uniform` application, so there is no
per-draw allocation; no signature changes and no `.mli` changes.

One thing that *does* change, and which "distribution unchanged" can
hide: every path now draws the selector plus the general value, so for a
given seed the sequence of draws differs from stock. Anyone pinning a
fixed seed in `Test.run` and expecting the same concrete cases will see
different ones. The distribution is preserved; per-seed reproducibility
across this change is not, in the same way it is not across any change
to draw structure.

## Effect

On the Shrinking Challenge, 100 runs each, `normalised / mean
evaluations`:

| challenge | before | after |
|---|---|---|
| reverse | 0/100, 294.0 | **50/100**, 278.8 |
| distinct | 0/100, 418.5 | **12/100**, 417.7 |
| large_union_list | 0/100, 1317.7 | 0/100, **1256.7** |

`max_int` disappears from the reported counterexamples entirely, and
mean cost goes *down* on all three — this is not a quality-for-time
trade.

Neither reaches 100/100; the remainder is a separate and milder instance
of the same thing (`bit_not` makes `-1` cheaper to encode than `1`),
plus reduction passes that need structural spans we do not have. I am
not proposing anything for those.

**One row moves the other way and I would rather explain it than omit
it.** On the suite's `bound5` challenge the score drops from 159/1000 to
52/1000 (95% CIs 13.7-18.3 and 4.0-6.8, non-overlapping — so a real
effect, not noise). That is not a worse counterexample: measured
directly over 1000 runs, all 1000 reduce to exactly two elements and 998
to the right content either way — two singleton lists holding `-1` and
`-32768`, three empties — and the challenge scores one exact permutation
of five symmetric slots. The change shifts which permutation wins.

The mechanism is worth knowing before you accept this, because it is a
real limit of the approach. The selector is recorded before the value,
so the branch reached by the *smallest* selector sorts ahead of every
other outcome however small its value. Putting `lo` first is right when
`lo` is the shrink target, which is the case for `int` — its magnitude
comes from `log_inclusive zero max_value`. For a range straddling zero,
such as int16's `[-32768, 32767]`, `lo` is an extreme instead, so
`-32768` sorts ahead of `-1`.

I tried the obvious repair — order the branches by distance from the
target, general branch first when the range straddles zero. It fixes the
value ordering and cuts cost 30%, but it makes normalisation worse (87
distinct answers against 17), because removing the strong `lo`-first
preference leaves many configurations tied. So the simple version above
is what I am proposing, with this known edge rather than a claim of
being uniformly better.

## Where this came from

Measuring an OCaml port of Hypothesis's Conjecture engine against the
Shrinking Challenge, written up here:

https://github.com/matthiasgoergens/tapecheck/blob/master/docs/porting-conjecture-to-ocaml.md

The full diagnosis, including the reordering attempt that failed and
why, is in
[`proposals/BASE-QUICKCHECK-ENCODING.md`](https://github.com/matthiasgoergens/tapecheck/blob/master/proposals/BASE-QUICKCHECK-ENCODING.md).

Happy to be told there is a reason it is written the way it is, or that
a PR is the wrong vehicle and this should be an issue instead — I do not
know how changes normally reach the internal tree.

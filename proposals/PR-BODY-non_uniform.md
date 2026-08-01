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
  let selector =
    create (fun ~size:_ ~random -> Splittable_random.float random ~lo:0. ~hi:1.)
  in
  bind selector ~f:(fun p ->
    map (f lo hi) ~f:(fun v ->
      if Float.( < ) p 0.05 then lo else if Float.( < ) p 0.95 then v else hi))
```

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

By construction: the selector is independent of the value, so this is a
pure reassociation of the same three-way choice.

Verified rather than asserted, over 400 000 draws of `Generator.int`:

| | before | after |
|---|---|---|
| magnitude = 0 | 6.415% | 6.452% |
| magnitude = `max_value` | 5.016% | 5.013% |
| neither | 88.570% | 88.534% |
| negative | 50.023% | 50.051% |

Magnitude bit-length histogram over 63 buckets: chi-square 36.5 on 63
degrees of freedom. Statistically indistinguishable.

## Cost

`f lo hi` is now always evaluated, so the 10% of draws that previously
took a shortcut pay two extra PRNG calls. Nothing else changes: no
allocation on the fast path, no change to any signature, no change to
any `.mli`.

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
it.** On the suite's `bound5` challenge the score drops from 17/100 to
7/100. That is not a worse counterexample: measured directly, 100 of 100
runs reduce to the right content either way — two singleton lists
holding `-1` and `-32768`, three empties — and the challenge scores one
exact permutation of five symmetric slots. The change shifts which
permutation wins.

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

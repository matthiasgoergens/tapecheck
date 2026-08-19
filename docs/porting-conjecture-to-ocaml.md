# Porting Hypothesis's shrinker to OCaml, and measuring what it cost

tapecheck is a port of the Conjecture engine — the choice-tape shrinker
inside [Python Hypothesis](https://hypothesis.readthedocs.io/) — to
OCaml's [`base_quickcheck`](https://github.com/janestreet/base_quickcheck).
None of the design is mine. What is mine is the port, and the
measurements, including the ones that came out badly.

This post is about the measurements. The short version: against an
independent benchmark suite, Hypothesis wins comfortably, three of our
losses turn out to be one fixable defect in the host library rather than
anything about the shrinker, and one class of loss is the price of a
design choice I would make again.

## Why this exists: a paper, and a library that had already done it

The project started with ["Property-Based Testing in
Practice"](https://harrisongoldste.in/papers/icse24-pbt-in-practice.pdf)
(Goldstein et al., ICSE 2024). It is a genuinely good paper — an
interview and survey study of how people actually use PBT, which is a
much harder thing to do than to propose another combinator library, and
it ends with concrete recommendations for what tools ought to offer.

The striking thing on reading it is how many of those recommendations
Hypothesis had already shipped, some of them years earlier. So rather
than invent anything, I ported them. Every row below is Hypothesis's
design; the measurement is the port's.

| The paper asks for | Hypothesis already has | Ported, and measured |
|---|---|---|
| Better reduction — counterexamples people can actually read | Internal reduction over the choice sequence | On six benchmarks the tape engine reaches the true minimum 100/100 and stock `base_quickcheck` 0/100 — but see the caveat below, because most of that gap is definitional |
| Reduction that explains *which parts matter* | The `explain` phase, free-variation analysis | Ported. On the paper's own `(0, 0)` example it reports the first component load-bearing and the second free, in 5–12 replays |
| Generators that find the interesting inputs | Edge-case-biased generation | Ported. A divisibility property goes from a 0.013% hit rate to 5.0%; end-to-end, 2/100 found-and-minimised to 100/100 |
| Visibility into what testing actually did | Statistics and health checks | All four Hypothesis health checks ported. They found two real bugs *in tapecheck* — `assume`'s exception being swallowed, and one check made unreachable by double-counting |
| Tests that fit a developer's time budget | — | Engine overhead 8.9 µs per call against Hypothesis's 609 µs, though see the caveat below |
| Steering the search toward hard-to-reach states | Targeted PBT (`target()`) | Ported from `optimiser.py` |

The reduction row deserves its caveat immediately. On scalar properties
the stock column is 0/100 at a cost of *zero test calls*, because
`Base_quickcheck.Shrinker.int` is `atomic` — literally
`fun _ -> Sequence.empty` — as are `bool`, `char`, `int32`, `int63` and
`int64`. base_quickcheck shrinks structure, not scalars, by design. So
0/100 there is not a shrinker being beaten; it is a shrinker that never
runs, and quoting it as a win would be dishonest. The rows where the
stock shrinker genuinely works are the list properties, where it still
reaches 0/100 — and `self_len`, where it reaches **46/100 against the
tape engine's 47/100**, which is a tie.

The time-budget row deserves its caveat too, because the number flatters
us and someone will otherwise do the arithmetic: a 69× overhead
gap only matters if the property itself is nearly free. A property doing
10 ms of real work sees 609 µs as 6%, not as a factor of 69. Where it
does bite is cheap properties run many times — data-structure laws,
round-trips, comparator invariants. And most of the gap is OCaml versus
Python rather than engine design.

That is the constructive half. The rest of this post is the other half:
where the port loses, and to what.

## The design choice

Hypothesis records at the *strategy* layer. Its strategies call
`start_span` / `stop_span`, so the shrinker sees a labelled, nested tree
over the recorded choices and can do things like "replace this whole
subtree with one of its descendants".

tapecheck records one layer lower, at the PRNG. A `splittable_random`
carrying an interception hook writes every draw to a tape as a typed,
bounded choice. Shrinking edits the tape and re-runs the generator on
it, accepting an edit if the test still fails and the recording got
shorter or simpler.

The payoff is that generators need to know nothing. Every existing
`base_quickcheck` generator — including everything `[@@deriving
quickcheck]` emits — becomes shrinkable with zero changes, no ppx and no
rewriting. The cost was that we had no spans, and four of Hypothesis's
passes need them: `remove_discarded`, `pass_to_descendant`,
`reorder_spans`, `minimize_duplicated_choices`. **All four have since
landed**, and the way they landed is the more interesting half of the
answer: rather than adopting strategy-layer spans wholesale, the
recorder gained opt-in capabilities that a generator sets on the
regions it wants treated structurally, and unchanged generators still
record nothing and pay nothing. `remove_discarded` and
`pass_to_descendant` came first (see the poisoned-trees table above and
`WAVE2-PASS-TO-DESCENDANT.md`); `reorder_spans` and
`minimize_duplicated_choices` followed, with their measurements and
their limits in `WAVE2-REORDER-AND-DUPLICATES.md`.

What that does not mean is that the gap closed. `reorder_spans`
normalises `bound5`'s answer set from 22 distinct arrangements to 2 but
still reaches the wrong canonical permutation, because tapecheck's
`non_uniform` encoding makes a two-entry `-32768` recording sort ahead
of `-1`'s three entries. The capability pattern generalised; the
shortlex order it feeds did not come out clean.

That trade is the subject of most of what follows.

## Measuring against a benchmark I did not choose

I had six benchmarks of my own, and against those the port matched
Hypothesis on quality. That sentence should be treated with suspicion:
picking your own benchmarks is exactly how "quality matched" gets said.

So I implemented [jlink's Shrinking
Challenge](https://github.com/jlink/shrinking-challenge), a
cross-language suite with published reports from ten libraries —
Hypothesis, jqwik, PropEr, FsCheck, fast-check, CsCheck, Americium,
elm-test, rapid, Exhaust. There is no OCaml entry.

The suite's report format is the right one and worth copying: for each
challenge, what the shrinker *normalises* to (does it reach the same
canonical answer regardless of where it started?) and what that costs in
test evaluations. Quality and cost together.

1000 runs per challenge, using ported challenge definitions and the same
evaluation-count convention. The execution controls are not identical:
tapecheck uses lower generation caps for `calculator` and `bound5`, a smaller
size for the exponentially growing calculator generator, and different shrink
limits. [CHALLENGE.md](../CHALLENGE.md) records the exact protocol and rerun
command. The published Hypothesis numbers are from 5.23.11 in 2020, so I
re-measured against current Hypothesis rather than citing them — it has
improved substantially since (`reverse` went from mean 45.95 evaluations to
17.65).

| challenge | Hypothesis 6.164.0 | tapecheck |
|---|---|---|
| reverse | **1000/1000**, 17.7 | 0/1000, 293.8 |
| distinct | **1000/1000**, 49.1 | 0/1000, 436.7 |
| large_union_list | **1000/1000**, 211.3 | 0/1000, 1338.8 |
| calculator | **1000/1000**, 103.3 | 16/1000, 912.0 |
| bound5 | **1000/1000**, 154.8 | 158/1000, 276.8 |
| lengthlist | **1000/1000**, 87.9 | **1000/1000**, 82.8 |
| difference (= 0) | 1000/1000, 40.5 | 1000/1000, 85.5 |
| difference (small) | 1000/1000, 721.6 | 1000/1000, **97.5** |
| difference (= 1) | 1000/1000, 885.2 | 1000/1000, **98.6** |

Cells are `normalised / mean evaluations`, 1000 runs each. tapecheck
column re-measured 2026-08-08 at `3aa0a47`; see `CHALLENGE.md` for the
patched arm and the four later-ported cases.

Hypothesis normalises all nine at 1000/1000. tapecheck reaches full
normalisation on four — the difference family, and lengthlist, which
was 683/1000 when this was written and is the one row the computed
repair moved. That is still the headline and it is still not close.

The rest of this post is what happened when I went through the losses
one at a time, because each turned out to have a different cause and
only one of them was the shrinker.

## Loss 1: the host library makes extreme values cheap

Every list-of-integers challenge came back full of
`4611686018427387903` — OCaml's `max_int` — where every other library in
the suite reports `1`:

```
## reverse
  expected      [0, 1]
  normalised    0/100 runs (10 distinct answers)
       45 x  [0, 4611686018427387903]
       16 x  [0, -1]
       15 x  [-1, 0]
        8 x  [4611686018427387903, 0]
```

The shrinker reported `converged = true` — a full round of every pass
finding nothing smaller. It had not given up. By its own ordering,
`max_int` really is smaller than `1`.

`base_quickcheck`'s `Generator.int` routes through:

```ocaml
let non_uniform f lo hi =
  weighted_union [ 0.05, return lo; 0.05, return hi; 0.9, f lo hi ]
```

`weighted_union` draws **one float** and binary-searches the cumulative
weights. `return lo` and `return hi` then draw *nothing further*, while
`f lo hi` draws two more choices. On the tape:

| value | recorded choices | length |
|---|---|---|
| `0` | `Bool false; Float 0.00` | 2 |
| `max_int` | `Bool false; Float 0.05` | 2 |
| `1` | `Bool false; Float 0.5; Int exp; Int mantissa` | 4 |

Shortlex ordering is length-first. A two-entry tape beats a four-entry
tape whatever the entries are, so `max_int` outranks `1` and no pass can
move off it. **The extreme values are the cheapest things to encode,
which is exactly backwards for a shrinker.** This is not specific to
tapecheck; it applies to anything ordering `base_quickcheck` generators
by their choice sequence.

The obvious fix does not work, and it is worth saying so because it is
the first thing anyone tries. Reordering the branches so `return hi` is
reached only by a *large* selector float changes nothing — measured,
`reverse` stayed at 0/100. Length is compared before the selector ever
is.

What works is drawing the selector first, always drawing the general
value, and ordering the branches lo / general / hi:

```ocaml
let non_uniform f lo hi =
  let selector =
    create (fun ~size:_ ~random -> Splittable_random.float random ~lo:0. ~hi:1.)
  in
  bind selector ~f:(fun p ->
    map (f lo hi) ~f:(fun v ->
      if Float.( < ) p 0.05 then lo else if Float.( < ) p 0.95 then v else hi))
```

Both properties are load-bearing and neither alone suffices. Equal
length stops the shortcut branches winning on length; selector-first
with `hi` last means that once lengths tie, position 0 decides and the
order it imposes is `0 < 1 < max_int`.

The distribution is unchanged by construction — the selector is
independent of the value — but that is the kind of claim worth measuring
rather than asserting. Over 400 000 draws of `Generator.int`: edge-case
rates match to within 0.04 percentage points, and the magnitude
bit-length histogram gives chi-square 36.5 across 63 buckets.
Statistically indistinguishable.

Effect: `reverse` 0/100 → 50/100, `distinct` 0/100 → 12/100, `max_int`
gone from the answers entirely, and mean cost *down* on all three
affected challenges. The cost to a non-tape user is that `f lo hi` is
always evaluated — two extra PRNG calls in the 10% of draws that take a
shortcut.

Patch and full write-up in [`proposals/`](../proposals/). It is
deliberately not applied to the vendored copy, which stays byte-identical
to upstream.

What remains after it is a milder second instance of the same thing:
`if negative then bit_not magnitude` makes `-1` cheaper to encode than
`1`, so the leftover answers are `[0, -1]` and `[-1, 0]`.

## Loss 2: the span gap, priced

Hypothesis's `tests/quality/test_poisoned_trees.py` is the sharpest test
in their quality suite, and it measures precisely the capability we
traded away.

A binary tree of leaves; each leaf is a 32-bit value drawn as two 16-bit
halves, and a leaf is *poisoned* iff both halves are at maximum —
probability 2⁻³², so fresh generation never produces one. Build a
minimal tree of *n* leaves, splice poison into one leaf position, and
ask the shrinker to reduce to that single leaf. The shrinker cannot
re-find the poison; it can only preserve it. Repeat for **every** leaf
position.

Ported with the same three sizes and two seeds as theirs, hence the same
34 leaf positions:

| | positions reduced to the poisoned leaf |
|---|---|
| Hypothesis 6.152.9 (their own test) | 34/34 |
| tapecheck, unchanged generators | 12/34 |
| tapecheck, opt-in descendable brackets | **34/34** |

The 12/34 floor is asserted in `test_poison/`; the 34/34 row needs the
opt-in capability that landed with `pass_to_descendant` on
`wave2/span-deletion` (see `WAVE2-PASS-TO-DESCENDANT.md`).

What makes this evidence rather than a score is that the failure has a
shape. Positions 0 and 1 reduce fully; from position 2 onward the
surviving tree grows monotonically with how deep the poison sits in the
tape — for the 10-leaf tree, 4, 5, 6, 8, 10, 10, 10, 10 leaves left.

The mechanism is legible. Poison early in the tape is isolated by
deleting what *follows* it, and suffix deletion is a pass we have.
Poison late requires deleting what *precedes* it — which shifts the
poison's own two draws into the position where a branch coin is read.
They get re-parsed as structure, the tree changes shape, and the poison
is destroyed. Span boundaries are exactly what let the subtree be
relocated intact, which is all `pass_to_descendant` is — and it now
exists, behind the opt-in capability.

`calculator` is the same gap in different clothing. Its misses are long
inert chains — `('+', ('+', ('+', 0, 0), 0), 0)` — wrapped around a
small failing subterm that cannot be promoted to the root.

Three details of their test are load-bearing, and I would have got each
of them wrong:

- **Two 16-bit halves, not one 32-bit draw.** Their comment says a
  single block would let block-move heuristics fire, "which would then
  allow us to shrink it more easily". They deliberately closed the easy
  route so the test measures the hard one.
- **A marker that must survive.** Without it, truncating the tape after
  the poisoned leaf is a valid shrink and the test passes for a reason
  unrelated to descending into a subtree.
- **Every position, not just one.** First and last are the easy cases.

The marker is the one to steal generally. Without it the test still
passes, still looks thorough, and checks nothing.

## Loss 3: mine, and the fix did not hold

`lengthlist` — draw *n*, then a list of exactly *n* elements, fail if
any exceeds 900 — sat at 64/100, and it is not explained by either cause
above.

Every miss stopped with `converged = false` and the global budget
untouched. That is a cap, not a capability gap. Bisecting the limits one
at a time found it: the per-pass failure cutoff. A pass gives up after
20 consecutive failures, and 20 is a very different fraction of a
200-choice tape than of a 20-choice one.

Making it a floor of `max 20 (len/3)` looked like a free win:

| property | flat 20 | proportional |
|---|---|---|
| list, len ≥ 3 | 50/50, 182 | 50/50, 182 |
| deep bind, sum ≥ 500 | 50/50, 148 | 50/50, 149 |
| lengthlist, max ≥ 900 | 34/50, 280 | **50/50, 137** |
| zig-zag, \|m−n\| ≠ 1 | 50/50, 34 | 50/50, 34 |

Full quality at half the cost, with all ten regression guards passing. I
committed it.

**It is wrong.** The poisoned-trees benchmark regressed badly under it:
the size-2 base tree stopped shrinking at 50 leaves instead of 2. I had
validated against the guard suite and four probe properties, but not the
whole suite — which is exactly the gap a guard suite cannot cover.

The reason is structural rather than a bad constant. The floor grants
long-tape patience to *unproductive* passes as well as useful ones, and
that patience is paid for out of the global budget — which is precisely
what the flat cutoff exists to prevent. Measured at divisors 3, 4, 6 and
8: at 3 the floor binds and poison breaks; at 4 and above it never binds
and nothing changes. There is no window.

Reverted. The real fix is *earned* patience — a pass's allowance scaled
by its own success rate, in the spirit of Hypothesis's
`fixate_shrink_passes` — which is a design change rather than a
constant, and is not done.

## Where the port wins

The `difference` family requires holding a dependency between two
separately-drawn integers. The challenge's own spec singles out
`difference_must_not_be_one` as "the most difficult one to shrink
because shrinking parameters individually will never lead to a smaller
and falsifying sample".

tapecheck matches Hypothesis's answer 1000/1000 at **9.0× lower mean
cost** — 98.6 evaluations against their 885.2 — and
near-deterministically (the 100-seed pilot measured an evaluation range
of 94..95 against their 54..1056).

That is `lower_together`, a port of Hypothesis's own
`lower_integers_together`, doing what it was ported to do. It got there
because their `test_zig_zagging.py` — as far as I can tell the only
shrink-*cost* test in their quality suite — caught the port falling
straight into the trap at 2929 calls, and porting the pass took it to
30.

## The question I cannot answer alone

Having also read Haskell's
[falsify](https://hackage.haskell.org/package/falsify), the axis that
matters seems to be not *where* structure comes from, but **how much
cooperation the shrinker needs from the generator**:

- **Hypothesis**: strategies must mark spans, and the engine shrinks
  over them.
- **falsify**: `Gen a = SampleTree -> (a, [SampleTree])` — every
  generator returns its own shrink candidates, and the engine takes the
  first that still fails.
- **tapecheck**: no cooperation at all, over unmodified generators — and
  since `wave2/span-deletion`, an opt-in capability that marks which
  labelled spans the recorder retains, which is how the first two of the
  four missing passes landed. The axis has therefore become a measured
  spectrum rather than a binary question.

I tried recovering spans from the PRNG's split topology. It fails for a
specific reason: `base_quickcheck` calls `split` exactly once in the
whole generator library, inside the *function* generator, so the keys
carry nothing about data structure. Making the combinators split does
produce the structure and roughly halves the tape — and shrink quality
then *drops*, 47/100 to 17/100, because our passes work within a flat
segment and the joint move they rely on stops being expressible.

So: is zero-cooperation viable for span-dependent passes, or is some
cooperation unavoidable? And if unavoidable, which currency is cheaper —
spans at the strategy layer, or shrink candidates from every combinator?

One data point running the other way. falsify's `Internal/Search.hs`
documents a parity bias in binary shrinking — "if we start with
`maxBound`, *every* possible shrunk value computed by `binarySearch` is
even" — and ships a `binarySearchNoParityBias` to counter it. tapecheck
does not have that bias: 240/240 exact minima on odd thresholds, same on
even. The reason looks structural. Their candidates must be enumerated
*before* any is tried, because generators emit them, so the search
cannot react to what it learns. An engine-driven search can. Generator
cooperation buys structure but costs adaptivity.

## Four measurement errors

Worth recording, because three of them flattered us and I would not have
caught any from reading. All four were found by review or by building
something specifically to embarrass the result.

**Budget mismatch.** The first challenge run gave tapecheck `count =
500` against their `max_examples = 10**6`. The `difference` rows read as
11/100 *found* — which measures a generation budget two thousand times
too small and says nothing whatever about a shrinker. At matched budget
they are 100/100.

**A repr artefact.** Hypothesis's `bound5` answer prints as `([], [],
[], [np.int16(-1)], [np.int16(-32768)])`, so a string comparison against
the challenge's stated answer scored it 0/100 while the values were
identical. It is 100/100. A false negative against the tool you are
comparing yourself to is the most comfortable kind of bug to have, and
the easiest to leave in place.

**Counting discards as counterexamples.** My Hypothesis harness decided
"is this interesting?" by catching plain `Exception`, and
`UnsatisfiedAssumption` is an `Exception`. On `calculator` — the one
challenge here that calls `assume` — every discard was recorded as
interesting, inflating the evaluation count with generation work. Their
true cost is 103.7, not the 191.2 I first measured, so the error made
Hypothesis look 1.8x more expensive than it is. Quality was unaffected.

**An exponential generator.** `calculator`'s expression generator is
`recursive_union` with two recursive branches out of three, so node
count grows exponentially in `size` — mean 37 nodes at size 8, 1357 at
size 20. Run at the suite's default size of 30, a 100-run sweep produced
nothing for half an hour. It runs fine at size 8. Hypothesis's
`st.deferred` has no size knob and is bounded by their buffer limit
instead, which is the more robust arrangement for a recursive generator.

The general lesson is the same one three times: a benchmark you wrote
yourself agrees with you by default. The measurement that changed my
mind was always the one built to embarrass the thing, not to confirm it.

## Reproducing

Everything is in [the
repository](https://github.com/matthiasgoergens/tapecheck).
`challenge/` is the OCaml side, the Python harness for current
Hypothesis is on the `hypothesis-baseline` branch, `test_poison/` is the
poisoned-trees port, and `test_regression/regression_guard.ml` holds the
quality-and-cost bounds, each one naming the specific regression it
exists to catch.

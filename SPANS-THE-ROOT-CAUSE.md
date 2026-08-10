# One missing structure explains three separate gaps

Written 2026-07-31, after mining Hypothesis's shrinker for the third
time in a day and finding the same wall each time.

## The three gaps, which looked unrelated

1. **`remove_discarded`** — filtered generators leave rejected draws on
   the tape and the shrinker minimises them. Measured: `minimize_choices`
   costs 95 on a filtered even-int against 37 for the same shape
   unfiltered. See `DISCARD-TRACKING.md`.
2. **`pass_to_descendant`** — replace an example with one of its own
   sub-examples. This is the bind-boundary move, and it is what
   `self_len` needs: reaching `[1]` requires crossing a generator branch,
   not lowering a value.
3. **`reorder_examples`, `minimize_duplicated_blocks`** — the rest of
   Hypothesis's pass list that tapecheck has no analogue for.

## They are all the same missing thing

Hypothesis's shrinker is built on **`examples`**: labelled, nested spans
with `start`/`end` offsets into the buffer, produced by the strategy
layer calling `start_example` / `stop_example`.

- `remove_discarded` needs `ex.discarded` — a span flag.
- `pass_to_descendant` needs `examples_by_label`, and `ancestor.start`,
  `ancestor.end` to find a sub-span to promote.
- `reorder_examples` needs spans to permute.
- `minimize_duplicated_blocks` needs block identity across positions.

**tapecheck has no span structure at all.** `Tape.image` is
`{ main : choice array; streams : (key * choice array) array }`, and
`key_elt` is `Split of int | Salt of int` — splittable_random topology,
not generator position. There is nowhere to hang a label, a start, or an
end.

That is not an oversight; it is the direct consequence of the design
choice that gives tapecheck its main practical advantage. Hypothesis
records at the STRATEGY layer, so it sees structure for free but only
for strategies it owns. tapecheck records at the PRNG layer, so it can
shrink *unmodified* `base_quickcheck` generators — no rewriting, no ppx,
no cooperation from the generator author — but it sees a flat sequence
of draws with no idea which draws belong together.

## Confirmed against base_quickcheck's own list generator

`generator.ml:345`, `sizes`:

```ocaml
let len = Splittable_random.Log_uniform.int random ~lo:min_length ~hi:max_length in
for _ = 1 to remaining do                    (* one draw PER UNIT of size budget *)
  let index = Log_uniform.int random ~lo:0 ~hi:max_index in
  sizes.(index) <- sizes.(index) + 1
done;
for i = 0 to max_index - 1 do                (* then a permutation *)
  let j = Splittable_random.int random ~lo:i ~hi:max_index in
```

The length is a single shrinkable draw, but the NUMBER and MEANING of
every draw after it depend on its value. Lowering it realigns the rest
of the tape, the value comes out garbage, the test stops failing, and
the edit is rejected. That is precisely the `self_len` failure, observed
in `diag2/probe_selflen.ml`.

## Hypothesis is also weak here, which is the interesting part

Their own quality suite marks the bind-boundary tests as unreliable:

```python
@flaky(min_passes=5, max_runs=5)
def test_can_ignore_left_hand_side_of_flatmap(): ...

def test_flatmap_rectangles():   # needs max_examples=2000
```

What `@flaky` actually does (tests/common/utils.py:53) is worth stating
precisely, because it is NOT a weakened oracle:

```python
while passes < min_passes:
    runs += 1
    try:    func(...); passes += 1
    except BaseException:
        if runs >= max_runs: raise
```

It loops until `min_passes` successes accumulate, forgiving failures
while `runs < max_runs` and re-raising afterwards. So it is
simultaneously STRICTER than an ordinary test — it demands five passes,
not one — and tolerant of occasional failure. The oracle is not
narrowed; the test is repeated.

The signal is still the one that matters: the decorator exists because
the outcome is non-deterministic, and someone decided that was
acceptable rather than fixable. So even WITH full span structure,
shrinking across a bind is acknowledged-hard. That matches the measurement: on `self_len`
tapecheck gets 47/100 and Hypothesis 53/100, and both get trapped on the
identical shape (a list of n zeros headed by n).

So the honest position is not "tapecheck is behind here". It is "this is
hard for both, we are 6 points behind with strictly less structure to
work with, and the structural question is open".

## The question worth asking, rather than answering alone

Can span structure be recovered at the PRNG layer, or is it inherently
lost? Three options were considered; one is now eliminated by
measurement, leaving two.

- **Give up nothing, gain nothing.** Accept that span-dependent passes
  are out of reach and compete on the passes that are not.
- **Own the combinators.** A tapecheck-provided `list`, `filter` etc.
  that bracket their draws. Exact, but forfeits the drop-in property for
  anything that opts in — the same trade as `DISCARD-TRACKING.md`.
- **Infer spans from splittable_random topology — dead as things stand,
  but only because of what the combinators currently do.** This was the attractive option, because it would get structure
  without any cooperation from generator authors. It does not work, and
  the reason is decisive rather than a matter of tuning:
  `Splittable_random.split` appears **exactly once in all of
  base_quickcheck's `generator.ml`** (`vendor/base_quickcheck/generator.ml:26`,
  re-checked 2026-08-08), inside `fn` — the
  FUNCTION generator — where it gives a function's body an independent
  stream so that repeated calls with the same argument stay
  deterministic. `perturb` serves the same purpose for arguments.
  Lists, tuples and binds never split. So `Split`/`Salt` keys record
  PRNG topology for function generation and carry no information
  whatsoever about data structure. `diag2/probe_selflen.ml` shows this
  directly: a 2-element list puts all 21 choices in `main` with zero
  streams. There is nothing to infer from.

  **But Matthias's follow-up is the right one: the combinators could be
  changed to split.** Tested (`diag2/probe_split.ml`) with a hand-written
  list generator that splits once per element:

  | | elements | main | streams | self_len quality | calls |
  |---|---|---|---|---|---|
  | stock `G.list` | 6 | 21 choices | **0** | 47/100 | 170 |
  | split list | 5 | 6 choices | **5**, 1 choice each | **17/100** | 53 |

  Two things confirmed and one surprise.

  Confirmed: the structure appears exactly as predicted — one stream per
  element, keys being paths so nesting would compose — and the tape
  roughly halves, which is the ~85%-bookkeeping finding arriving from
  another direction.

  Surprise: **shrink quality gets WORSE, 47/100 down to 17/100.** The
  passes operate within a segment, so with the length choice in `main`
  and the element values on separate streams, the "lower the length and
  delete an element" move cannot be expressed at all. The structure is
  present and the shrinker is not built to use it.

  So this is not a free win, and it is a bigger change than it first
  looks: it needs matching shrinker work, not just a generator change.
  There *was* an encouraging detail here: tapecheck had a
  `delete_streams` pass measuring 0 attempts on every property, dormant
  only because nothing ever splits, which under split generators would
  become the element-deletion primitive.

  **It was removed on 2026-08-09 (issue #8), and the encouraging reading
  did not survive being measured.** It is not that the pass had no
  workload; it is that on the workload built specifically to favour it —
  a generated function probed at twelve arguments where only one decides
  the verdict, so eleven whole streams are removable noise — it reached
  the *same* minimal while costing 38% more attempts (63 against 39).
  The existing fn tests agree: identical minimals, 16→15, 22→18 and 7→5
  attempts without it, and the whole challenge suite at n=1000 is
  byte-identical with it gone. A pass that cannot pay on its own best
  case is not half-built machinery, it is cost.

  If split generators ever land, the element-deletion primitive should
  be written against the structure that actually exists then, rather
  than resurrected from this one on the strength of the name matching.
  `probe_deadpasses/` is kept so that argument can be re-run rather than
  re-remembered.

  Whether the change is a good idea remains open. It is a breaking change
  to generated values (versionable, per the discussion below), it costs
  shrink quality until the passes are rewritten, and the benefit accrues
  to replay-based tools rather than to ordinary base_quickcheck users.

### On changing base_quickcheck's list generator

I first argued against proposing this, on the grounds that changing the
encoding changes generated values for every seed and so breaks every
expect test recording generated output. **Matthias pushed back and is
right**: that is an ordinary migration concern, handled by a version bump
or by versioning the recorded encoding so old seeds still reproduce.
Libraries make deliberate breaking generator changes routinely. The
objection was about migration cost, not about merit, and I was treating
it as a blocker.

So the question reduces to whether the encoding is worse on its merits.
**Measured, and it is** (`diag2/probe_drawcount.ml`, 200 seeds per row):

| `~size` | tape choices | list elements | choices/element |
|---|---|---|---|
| 5 | 8.2 | 1.7 | 4.70 |
| 10 | 16.5 | 3.5 | 4.72 |
| 20 | 33.4 | 6.2 | 5.43 |
| 40 | 66.8 | 10.8 | 6.19 |
| 80 | 131.6 | 19.4 | 6.79 |

Tape length is **~1.65 x `size`, independent of the resulting list
length**. At `size = 80` that is 131 choices for a 19-element list, where
the element values account for 19 of them. Roughly 85% of the tape is
size-budget bookkeeping: the `for _ = 1 to remaining` loop draws once per
unit of budget, then a permutation pass draws again per element.

**CORRECTED by profiling realistic shapes** (`diag2/probe_realshapes.ml`).
"~85% bookkeeping" was measured on `G.list` alone and generalised too
far. Per unit of actual data, at `~size = 10`:

| shape | choices/unit |
|---|---|
| record, 4 scalar fields | **1.00** |
| Blang-like recursive tree (hand-written bind) | **1.20** |
| int list | 4.72 |
| string | 5.00 |
| assoc map (int -> int) | 5.72 |
| option list | 5.22 |
| **list of lists** | **15.46** |

The overhead is not a property of the tape or of base_quickcheck
generally. It is **specifically `G.list`'s `sizes` machinery, and it
COMPOUNDS with nesting** — a list of lists pays it at both levels.
Hand-written recursive generators and plain records are essentially
optimal at 1.0-1.2.

(Shapes are reconstructions of types carrying `[@@deriving quickcheck]`
in `janestreet/core`, notably `Blang.t`. core's own generators are not
reachable because `core/test` does not build outside Jane Street.)

That makes the upstream case *better*, not worse: the cost is localised
to one combinator, so changing `list` — or adding a shrink-friendly
alternative beside it — captures nearly all of the benefit without
touching the rest of the library.

Two consequences, one general and one ours:

- **General**: generation spends O(size) PRNG draws to decide how to
  split a budget among O(size/4) elements. Whether that matters for
  ordinary users depends on whether draws are a real cost next to the
  element generation they gate — not established here.
- **Ours**: every shrink pass is O(choices) or worse, so a 5-7x inflated
  tape is a 5-7x inflated shrink. This is a direct, measured cost of the
  encoding to any replay-based tool.

A less invasive option than changing the default: add a shrink-friendly
list generator alongside it, so nothing existing moves. That fragments
the API, which is its own cost, but it needs no migration at all.

## Prototyped: does a better list encoding actually help?

`diag2/probe_listgen.ml`. Two alternatives to `G.list`, both trivial:
`list_len` (draw the length once, then that many elements) and
`list_cont` (a continuation bool before each element, which is what
Hypothesis's `lists()` does).

Length distributions matched — a first run used a 1/2 continuation
probability, giving mean length 1 against `G.list`'s 3.5, which made the
comparison partly about distribution rather than encoding. At 3/4 the
means are 2.9 vs 3.5.

| | G.list | list_len | list_cont |
|---|---|---|---|
| tape choices per element | 4.72 | 5.26 | **2.34** |
| `length >= 3` quality | 100/100 | 100/100 | 100/100 |
| `length >= 3` cost | 178 | 183 | **560** |
| `sum >= 100` quality | 100/100 | 100/100 | 94/100 |
| `sum >= 100` cost | 173 | 177 | **84** |
| **`self_len` quality** | **47/100** | 47/100 | **92/100** |
| `self_len` cost | 170 | 206 | 135 |

**The diagnosis is confirmed.** `self_len`'s 47/100 really was a
generator-encoding limit, not a shrinker gap: changing only the encoding
takes it to 92/100, which also clears Hypothesis's 53/100 comfortably.
`list_len` changes nothing, which is the right control — drawing the
length as one number still leaves everything downstream dependent on it.

**But it is not a uniform win**, and that matters more than the headline.
`list_cont` costs 3x on `length >= 3` and loses 6 points of quality on
`sum >= 100`. Interleaving a bool before every element gives the passes
more to chew on: deletion becomes easy, but reaching exactly `[0;0;0]`
now means driving both the bools and the values.

So the honest summary is that the encoding choice trades one class of
property against another, rather than dominating. Which is a better
thing to put to base_quickcheck's maintainers than "yours is worse":
the question is which class matters more in their tests, and that is
theirs to answer, not mine.

## Measured: what the missing spans cost, in a number

Everything above argues the gap from the design. Hypothesis's
`tests/quality/test_poisoned_trees.py` measures it, and it turns out to
be the sharpest instrument in their suite for exactly this.

The setup: a binary tree of leaves, each leaf a 32-bit value drawn as
two 16-bit halves. A leaf is *poisoned* iff both halves are at maximum —
probability 2^-32, so fresh generation never produces one. Build a
minimal tree of `size` leaves, then artificially splice poison into one
leaf position and ask the shrinker to reduce to that single leaf. Repeat
for **every** leaf position. The shrinker cannot re-find the poison; it
can only preserve it.

Three details of theirs are load-bearing and worth keeping when porting:

- **Two 16-bit halves, not one 32-bit draw.** Their comment says a
  single block would let block-move heuristics fire "which would then
  allow us to shrink it more easily". They deliberately closed the easy
  route so the test measures the hard one.
- **A marker must survive.** Otherwise truncating the tape after the
  poisoned leaf is a valid shrink, and the test passes for a reason
  unrelated to descending into a subtree. This is the anti-vacuity
  device, and without it the whole thing is decorative.
- **Every position, not just one.** First and last are the easy cases.

Ported to `test_poison/`. Same three sizes (2, 5, 10) and two seeds as
theirs, hence the same 34 leaf positions. First measured 2026-08-01,
re-measured 2026-08-08:

| | positions fully reduced |
|---|---|
| Hypothesis 6.152.9 (their own test) | 34/34 |
| tapecheck | 12/34 (10/34 on 2026-08-01) |

The failure has a shape, which is what makes it evidence rather than a
score. The ENDS reduce and the middle does not: for the 10-leaf tree
only positions 0 and 9 come out, and between them the surviving tree
grows monotonically with how deep the poison sits in the tape — 3, 4,
5, 6, 8, 10, 10, 10 leaves left at positions 1 through 8. The 5-leaf
tree reduces at 0, 1 and 4 and sticks at 4 and 5 leaves in the middle.
(The 2026-08-01 measurement recorded positions 0 and 1 reducing, with
4, 5, 6, 8, 10, 10, 10, 10 left; the extra two positions in the 12/34
total are the last leaf of each 10-leaf tree.)

The mechanism is legible. Poison early in the tape can be isolated by
deleting what *follows* it, and suffix deletion is a pass we have.
Poison late requires deleting what *precedes* it — which shifts the
poison's own two draws into the position where a branch coin is read.
They get re-parsed as structure, the tree changes shape, and the poison
is destroyed. Span boundaries are precisely what would let the subtree
be relocated intact, which is all `pass_to_descendant` is.

So the cost of PRNG-level recording, on the one benchmark built to
measure it, is 24 of 34 positions. That is a bigger number than the
prose above implied, and it is the honest one to quote.

### Two notes from porting it

The engine's own `large_base_example` health check caught a modelling
error on the first run: with the branch coin written so that the
*minimal* choice means "branch", the minimal tape is a full tree of
depth 12. Inverting the comparison so the minimal choice terminates
fixed it. Worth recording because the health check was written for
user generators and caught a bug in our own test instead.

Finding the leaf positions needed no span metadata on our side. Their
version reads them off `data.blocks`; our choice tape is typed, so a
leaf draw is identifiable by its own recorded bounds (`hi = 65535`).
Splicing is likewise encoding-agnostic — `Integer {value; lo; hi}`
becomes `Integer {value = hi; lo; hi}`, "set this draw to its maximum",
with no need to know how `int_uniform_inclusive` maps onto the PRNG.
A typed tape is worth something even where a flat one has spans.

## A span-free approximation of `reorder_spans`, not yet built

`bound5` sharpened the question of whether sibling ordering is even
canonical. It is, and Hypothesis says so explicitly. `sort_key` is
shortlex over choices — "x is simpler than y if x is shorter, or the
same length and lower per-choice index" — and `reorder_spans` sorts a
span's children that share a label using `Ordering.shrink` with that
key. Their docstring gives the motivating case:

> `@given(st.text(), st.text())` with `assert x != y` — "Without the
> ability to reorder x and y this could fail either with `x=""`,
> `y="0"`, or the other way around. With reordering it will reliably
> fail with `x=""`, `y="0"`."

So the canonical answer is the *sorted* arrangement, and counting any
permutation as equally minimal would discard the property being
measured. Reliably reporting the same counterexample is the benefit.

We cannot do this the way they do: their pass needs span boundaries to
know where a child starts and ends, and labels to know which children
are comparable.

**But we already use a stand-in for "comparable" elsewhere.**
`correlate_image` treats two integer choices with identical bounds as
the same kind of thing, on the grounds that equal bounds means the
generator drew them from the same range. That heuristic lifts from
single choices to segments: two tape subsequences with an identical
signature — the same sequence of `(kind, lo, hi)` — are plausibly
sibling draws of the same generator, and can be ordered with the
existing `compare_shortlex`.

Sketch of the pass:

1. Scan the main stream for maximal runs of repeated signature. On
   bound5 the five slots share a signature, so the run is found without
   any span information.
2. Sort those segments by `compare_shortlex` and propose the result.
3. Accept on the usual condition: still fails, and the re-recorded tape
   is shortlex-smaller.

What it would and would not reach. It should handle `bound5`, where the
siblings are fixed-shape and adjacent. It will miss variable-length
siblings, whose signatures differ precisely because the contents differ
— which is most list elements, and probably `large_union_list`. So this
is a partial recovery, not a replacement, and it should be measured
against both before being believed.

Worth stating the risk plainly: signature equality is a guess about
structure. Two unrelated draws with coincidentally identical bounds
would be reordered against each other. That is safe for correctness --
every proposal is still validated by re-running the test -- but it costs
attempts, and the per-pass cutoff already showed that a pass which
scores no successes is expensive. Any implementation needs the
regression guard's cost bounds watching it.

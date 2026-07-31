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
- ~~**Infer spans from splittable_random topology.**~~ **TESTED AND
  DEAD.** This was the attractive option, because it would get structure
  without any cooperation from generator authors. It does not work, and
  the reason is decisive rather than a matter of tuning:
  `Splittable_random.split` appears **exactly once in all of
  base_quickcheck's `generator.ml`** (line 87), inside `fn` — the
  FUNCTION generator — where it gives a function's body an independent
  stream so that repeated calls with the same argument stay
  deterministic. `perturb` serves the same purpose for arguments.
  Lists, tuples and binds never split. So `Split`/`Salt` keys record
  PRNG topology for function generation and carry no information
  whatsoever about data structure. `diag2/probe_selflen.ml` shows this
  directly: a 2-element list puts all 21 choices in `main` with zero
  streams. There is nothing to infer from.

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

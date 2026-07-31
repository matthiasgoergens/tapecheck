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
lost? Options, none obviously right:

- **Give up nothing, gain nothing.** Accept that span-dependent passes
  are out of reach and compete on the passes that are not.
- **Own the combinators.** A tapecheck-provided `list`, `filter` etc.
  that bracket their draws. Exact, but forfeits the drop-in property for
  anything that opts in — the same trade as `DISCARD-TRACKING.md`.
- **Infer spans from splittable_random topology.** `Split` keys already
  record where the generator branched. Whether that is a usable proxy
  for example nesting is an open empirical question and the most
  interesting one, because it would get structure without cooperation.

### On changing base_quickcheck's list generator

Tempting, and probably wrong to propose on its own. Stock
`Shrinker.list` works on values rather than the tape, so the encoding
does not affect ordinary base_quickcheck users at all — the
beneficiaries are replay-based tools. And changing it changes generated
values for every seed, breaking every expect test that records generated
output, which Jane Street relies on heavily. Asking someone to take that
churn for a downstream tool's benefit is a bad trade.

One piece might stand alone: the loop draws once per unit of size
budget, so draw count is O(size) merely to decide element sizes. That
looks like an inefficiency on its own terms. NOT MEASURED — a question,
not a claim, and it should be measured before being raised anywhere.

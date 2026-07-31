# Can tapecheck do Hypothesis's `remove_discarded`?

Measured problem: `filtered even ints` costs 95 attempts in
`minimize_choices` against 37 for the same generator shape unfiltered,
and 27 for Hypothesis end to end. See
`../tapecheck-hypothesis-baseline/README.md`.

Hypothesis's fix is `remove_discarded` (shrinker.py:1085): delete every
span marked discarded, all at once. Spans get marked by `.filter()`
calling `stop_example(discard=True)`.

## Why it does not port directly

**Hypothesis records at the strategy layer; tapecheck records at the
PRNG layer.** That difference is not incidental — recording draws from a
`splittable_random` is exactly what lets tapecheck shrink *unmodified*
`base_quickcheck` generators, including ones whose authors never heard
of it. It is the port's main practical advantage over a rose-tree
library. But it costs the structure Hypothesis relies on.

**The information is lost, not merely unrecorded.** `base_quickcheck`'s
`filter` retries by invoking the generator again on the same random
state, so a rejected attempt appears as ordinary consecutive draws. A
filtered even-int leaves a run of `Integer {lo=0; hi=100_000}` choices
on the tape — indistinguishable from a genuine two-element list of ints
over the same range. Tape keys do not disambiguate: `key_elt` is
`Split of int | Salt of int`, describing splittable_random structure,
not generator position. So no post-hoc heuristic can recover which
draws were discarded.

## The hook that does exist

`Tape.choice` already has a `Marker` constructor, used for split/perturb
alignment — a non-value entry the shrinker treats specially. A discard
marker is the same shape of thing, so the tape representation is a small
extension rather than a redesign.

What it needs is a `filter` that tapecheck owns, bracketing each attempt
and marking the failed ones. That is the same move Hypothesis makes; the
difference is only that Hypothesis's users already go through its
`.filter()` whereas tapecheck's go through `base_quickcheck`'s.

## Options, with the tradeoff stated

**A. tapecheck-provided `filter` (opt-in).** Exact, matches Hypothesis,
and preserves the "works with unmodified generators" property for
everyone who does not use it. Cost: two ways to filter, and the fast
path only applies to code that opted in. This is the recommended one —
opt-in means nothing regresses.

**B. A general contiguous-run deletion pass, no marking.** Hypothesis
notes that its adaptive deletion pass finds discards anyway, just more
slowly; `remove_discarded` is an optimisation over it. tapecheck already
deletes blocks (`with_deleted_block`, k <= 4) inside `lower_and_delete`
— but that pass measures **0 attempts on filtered even**, so it never
fires there. Worth understanding why before building anything: if the
existing machinery is simply not reaching this case, the fix may be much
smaller than a new pass.

**C. Do nothing yet.** The filtered gap is ~3.5x on one property. The
list gap is 20x, has a cheaper fix (`find_integer` galloping search),
and covers three of the six rows. Priority is clearly the list bug.

## Recommendation

Do the galloping search first — bigger effect, smaller change, already
queued. Then investigate B's question (why does `lower_and_delete` never
fire on filtered generators?), because the answer determines whether A
is needed at all. Reach for A only if B turns out to be a dead end.

Deliberately NOT doing: pass reordering. The measurement showed the
expensive pass is also the productive one, so scheduling cannot help.

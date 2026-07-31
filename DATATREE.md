# Reading DataTree properly, rather than porting the vague idea

I shipped a determinism check that replays one image twice and compares.
Matthias asked what happens when a generator is only *occasionally*
flaky; the answer was 3% detection at 1% flakiness. His follow-up was
the right instruction: read their code, because "the code also has all
the scars of real world usage". It does, and my version is not a small
approximation of theirs — it is a different and much weaker thing.

## What they actually do

`TreeRecordingObserver` (`datatree.py:309`) is an **observer on every
draw of every test case**, not a check run once. Each draw walks a
shared tree. Effective sample size is the whole run, not `k`.

## The distinction I would have got wrong

**Differing VALUES are not inconsistency.** A different value causes
`node.split_at(i)` and creates a branch — that is the tree *exploring*,
and it is the normal case. Only differing **structure** is flagged:

- `n_bits != node.bit_lengths[i]` — a draw of a different *width* at the
  same position. Caught even when the value coincides.
- `forced and i not in node.forced` — a previously-free draw now forced.
- drawing at all where history recorded a `Conclusion`: *"We tried to
  draw where history says we should have stopped"*.
- concluding where history says draws remained.

My image comparison conflates these. It happens to be roughly right for
the narrow case I use it in — replaying a *fixed* image, where values
should come from the tape, so any divergence means drawing outside it —
but it is not the same idea and does not generalise.

## Two scars worth having read

**A deliberate coverage hole, with the reasoning:**

> Note that we don't check whether a previously forced value is now
> free. That will be caught if we ever split the node there, but
> otherwise may pass silently. This is acceptable because it means we
> skip a hash set lookup on every draw and that's a pretty niche failure
> mode.

A per-draw cost traded against a rare miss, decided and written down.
Nobody would infer that from the design.

**An acknowledged unsound case:**

> As an, I'm afraid, horrible bodge, we deliberately ignore flakiness
> where tests go from interesting to valid, because it's much easier to
> produce good error messages for these further up the stack.

So `INTERESTING -> VALID` transitions are *not* reported here, on
purpose, because a better message exists elsewhere. That is a
whole-system decision invisible from this file alone, and precisely the
sort of thing a paper would never mention.

## Do their scars transfer to us?

Matthias's follow-up, and the right question: a scar is a decision under
someone's constraints, so copying it uncritically is the same error as
ignoring it. Both were checked.

### Scar 1 (skip the hash lookup): NO, we can afford it

I reasoned twice and was wrong twice, then measured.

First guess: "we are 69x cheaper per call, so we can afford what they
skipped". Backwards — if draws are cheap, a fixed-cost lookup is a
*larger* proportion.

Second guess, from measurement: `Hashtbl` lookup 21.2 ns against a
136.8 ns recorded draw, i.e. **15.5% of a draw**, so the scar transfers
*more* strongly to us.

Matthias then pointed out that proportion-of-a-draw is the wrong
denominator. What a user pays is absolute time, and draws are only part
of a test call:

```
draws are ~25% of a test call (2.2 us of 8.9 us)
adding one hash lookup per draw: +0.34 us per call = +3.8%

  over      1,600 draws (a typical run): +0.00002 s
  over    100,000 draws:                 +0.002 s
  over 10,000,000 draws:                 +0.21 s
```

**+3.8% per test call, and microseconds per run in absolute terms.** For
a check that catches silently-broken generators, that is cheap. The scar
does not transfer: their trade was made in a language where the
denominator looks different, and we should take the check they declined.

### Scar 2 (ignore INTERESTING -> VALID): NO, and worse

They tolerate that hole *because* "it is much easier to produce good
error messages for these further up the stack" — i.e. the case is
handled elsewhere in their system. tapecheck has no such upstream
machinery. Porting the bodge would buy the hole without the
compensation, which is strictly worse than either handling it here or
building the upstream message first.

So: two scars read, two scars rejected, for opposite reasons. Reading
them was still worth it — the *reasoning* transferred even where the
decisions did not.

## What this means for tapecheck

The honest position is that the two-replay check is a cheap smoke
detector, not a port of DataTree, and the module comment now says so
with the measured detection curve.

A real port wants the observer shape: check on every replay rather than
sampling. tapecheck already replays hundreds of times per shrink, so the
sample size is there for free — what is missing is a place to hang the
expected structure. That is the *third* thing this session has traced
back to not having spans (`SPANS-THE-ROOT-CAUSE.md`): draw widths and
positions are exactly the structure a tree would key on.

Also unported, and separable: **exhaustion detection**. `check_exhausted`
/ `__update_exhausted` let the engine know the search space is finished
and stop early rather than re-drawing cases it has already seen. That is
a distinct feature from flakiness detection, sharing only the tree.

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

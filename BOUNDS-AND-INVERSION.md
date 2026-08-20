# Two questions about what the tape carries

Written 2026-08-20 against dedc087. Every file:line below was read at
that commit.

## Why bounds are recorded, including on replay

Replay does not consume a recording, it *produces* one. `draw_int`
(`tape/tape.ml:555`) pops the recorded entry, keeps only its value, and
clamps that to the bounds the generator is asking for **now**:

    | Some (Integer { value; _ }) -> clamp_int64 value ~lo ~hi

and then re-records the choice with those live bounds
(`tape/tape.ml:566`). The output of a replay is the image the shrinker
then works on, so the bounds have to be there.

They have to be there because **every shrink pass reasons about the
image offline**, without running the generator. Four consumers, all of
which would be undefined without bounds:

- `Tape.Domain.target` / `at_target` (`tape/tape.ml:964`, `971`). The
  shrink target is `clamp 0 [lo, hi]`, which is `0` only when `0` is in
  range. Without the bounds there is no target, so `trivialize` and the
  shortlex image comparison have nothing to compare against.
- The lower-toward-target scan and its offset variant
  (`engine/tape_engine.ml:1858`, `2058`), both guarded by
  `value <> clamp64 0L ~lo ~hi` -- the test for "is this choice already
  as low as it can go".
- Duplicate grouping (`engine/tape_engine.ml:1423`), keyed on
  `(kind, value, lo, hi)`. Two choices with equal values but different
  ranges are different choices and must not be lowered as one group.
- The block signature (`engine/tape_engine.ml:1636`), keyed on
  `(kind, lo, hi)`, which is how repeated structure is matched across
  positions.

So: recorded bounds are what make a tape self-describing enough to edit
without executing it. That is a good reason and it is load-bearing.

**Using the live bounds rather than the recorded ones is also right** --
the generator is the authority on what is legal this time round, and
after the shrinker has lowered a list length the element draws
legitimately ask narrower questions.

**What is wrong is that the divergence is silent.** `t.misaligned`
(`tape/tape.ml:152`, set at `439` and `448`) fires only on a *kind*
mismatch, Integer against Bool. A bounds mismatch is a strictly finer
misalignment and is absorbed by the clamp with no signal at all. That is
the mechanism behind the `~size`-is-ambient finding: a tape recorded at
size 14 and replayed at size 10 asks narrower questions, values clamp,
the decoded value differs, and nothing says so. In `test_pairwise_witness`
it silently emptied two of three subjects, and only the non-vacuity
assertion caught it.

The fix is not a flag -- bounds divergence is routine during shrinking
and an assertion would fire constantly. It is a **counter**, surfaced
alongside the other statistics. The sharp case it makes checkable: the
first replay of an *unmodified* tape in the context that recorded it must
show zero divergences. Any divergence there means the ambient context
changed. That is precisely the `~size` bug, and it would have been a
one-line report rather than a two-hour trace.

## What parsing a value back into a tape would take

There is no general inverse and there cannot be one. A generator is an
opaque `size:int -> random:t -> 'a`. `map f` is not injective, so
inverting it needs `f`'s inverse, which only the user has. `filter`
discards. `bind` makes the shape of later draws depend on the earlier
value, so an inversion has to run forwards and can dead-end. And this
tape records at the *PRNG* level, not the strategy level, so a choice
does not even say which combinator asked for it.

**Hypothesis has not solved this either.** It has generalised the
forcing primitive to every choice type -- `forced` on `draw_integer`,
`draw_float`, `draw_string`, `draw_bytes`, `draw_boolean`
(`internal/conjecture/data.py:745-785`, 6.152.9) -- and records
`was_forced` per node. But there is no value-to-tape facility anywhere
in the tree; forcing is used by strategies at generation time, such as
pinning a continuation to `False` at the maximum length, not to invert
anything.

So the honest shape of the feature is opt-in and user-supplied, and it
splits into one cheap well-precedented piece and one speculative one.

**Cheap and independently worth doing: generalise forcing.** We have
`?forced` on `draw_bool` only (`tape/tape.ml:627`), plus
`Splittable_random.bool_with_probability ?forced`. `draw_int` and
`draw_float` have none. Hypothesis has all five. This is the primitive
any inversion would be built on, and it pays for itself without one.

It comes with a second gap: we do not record *that* a choice was forced.
`draw_bool` records a plain `Bool value` at `tape/tape.ml:636`. Hypothesis
marks the node and its shrinker treats forced nodes as immovable -- a
forced node is `trivial` by definition and `copy(with_value=...)` on one
is an assertion error (`internal/conjecture/choice.py:100`, `122`).
Without that bit our shrinker will keep proposing changes to forced
choices; the generator forces them back, the re-recording is identical,
the shortlex comparison yields 0, and the proposal is rejected. Wrong
answers are not possible, wasted attempts are. Unmeasured here -- the
number to get is the rejected-proposal rate on a generator that forces
often, which the continuation lists do at every maximum length.

**Speculative: the inverse itself.** The known shape is a partial
isomorphism -- Rendel and Ostermann, "Invertible Syntax Descriptions:
Unifying Parsing and Pretty Printing", Haskell Symposium 2010 -- a
parallel set of combinators carrying both directions, where `map` takes
`f` and `f^-1`. That is a whole second API surface and every user
generator has to be rebuilt in it. The cheaper opt-in, and the one that
fits what is already here, is to let a user supply an *unparser* for
their own generator that drives forcing: run the generator forwards in a
mode where each draw asks "given that we are building `v`, what should
this be?", answer with `forced`, and record the tape that results.
Best-effort is honest for it -- a `filter` or an unlucky `bind` can
dead-end, and the answer is then "no tape", not a wrong one.

Neither piece is scheduled. The first is small enough to do whenever the
forcing gap next gets in the way; the second should wait until there is a
user who wants it, because the API cost is the whole cost.

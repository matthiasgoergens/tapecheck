# Comment to post on janestreet/splittable_random#2

To go up *after* the base_quickcheck PR is filed, so it can link to it.
Deliberately short: this is updating an open thread, not relitigating it.

---

Context update rather than a nudge — I have written up what the seam was
for, and the measurements are less one-sided than my earlier comments
here implied.

https://github.com/matthiasgoergens/tapecheck/blob/master/docs/porting-conjecture-to-ocaml.md

Short version: on the cross-language
[Shrinking Challenge](https://github.com/jlink/shrinking-challenge),
Hypothesis normalises 9/9 at 100/100 and the port manages 3/9. So your
third objection — that this does not fit `base_quickcheck`'s model of
shrinking — is one I would now put more strongly than you did. It is a
different model, and on the benchmark that model is currently behind.

Two things came out of the exercise that may be useful independently of
whether this PR goes anywhere:

- Three of the losses are not the shrinker at all, but
  `Generator.non_uniform`'s edge-case shortcut, which makes `max_int` a
  two-draw path and `1` a four-draw path — so anything ordering by the
  recorded choice sequence ranks `max_int` below `1`. Filed separately
  as PR_URL, with a distribution check at 400k draws.
- Hypothesis's own `test_poisoned_trees.py` prices the span-dependent
  passes precisely: 34/34 for them, 10/34 for us.

No action needed on this PR from my side, and I remain happy to close it
if the approach is not one Jane Street wants to carry — the vendored
patch works and the tax falls only on me.

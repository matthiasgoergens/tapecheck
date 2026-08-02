# The length repair, and why lengthlist is still a frontier

`lengthlist` (jlink/shrinking-challenge) is `bind` a length `n` in
`[1,100]`, then a list of exactly `n` integers in `[0,1000]`, failing iff
some element is `>= 900`. The minimal answer is `[900]`. Hypothesis
reaches it 100/100; tapecheck reached it 73/100 at 256 calls.

This records what Hypothesis actually does, that tapecheck now has the
same mechanism, and why that did **not** close the gap — because the
blocker turned out to be pass order rather than the missing move, and
fixing the order costs a different guarded property.

## What carries lengthlist in Hypothesis

An ablation over seeds 0–99 of Hypothesis 6.152.9, counting all
test-function evaluations:

| configuration | optimal | mean evals |
|---|---|---|
| unmodified | 100/100 | 87.2 |
| `pass_to_descendant` off | 100/100 | 87.2 |
| `minimize_duplicated_choices` off | 100/100 | 87.2 |
| `redistribute_numeric_pairs` off | 100/100 | 87.2 |
| `lower_integers_together` off | 100/100 | 87.2 |
| `reduce_each_alternative` off | 100/100 | 87.2 |
| `reorder_spans` off | 100/100 | 90.2 |
| `try_trivial_spans` off | 100/100 | 84.9 (a net *cost* here) |
| **`minimize_individual_choices` off** | **14/100** | 64.1 |

And inside that pass, removing only the length-repair retry gives
**51/100**, with every failure of the form `[0,…,0,900]` — elements
zeroed, length never coming down.

Two conclusions worth stating plainly, because both contradict what I
expected before measuring.

**Spans are not load-bearing.** With `try_trivial_spans`,
`reorder_spans`, `pass_to_descendant`, `reduce_each_alternative` and
`minimize_duplicated_choices` all disabled *and* the span-derived blocks
excised from `try_shrinking_nodes`, Hypothesis still scores 200/200 at
90.6 evaluations against 87.2 stock. A shrinker with no span information
whatsoever solves this within 4%. The span machinery is worth about
three evaluations.

**It is not the continuation-bool encoding either.** Because
`min_size == max_size == n`, `cu.many` draws no boolean at all
(`utils.py:301-304`), so the choice sequence for a 3-element list is
literally `(3, 5, 900, 7)` — the same flat length-prefix-then-elements
shape tapecheck already records.

## The move

In `try_shrinking_nodes` (`shrinker.py:1146`):

> lower the integer at index `i` to `v` and replay; if the replay was
> *not* interesting but consumed `L` fewer choices than it was handed,
> retry with exactly the `L` choices immediately after `i` deleted.

The deletion size is **computed, never searched**. Its partner is a
replay convention rather than a pass: over-long attempts are truncated
and surplus trailing choices ignored, so lowering `n` also gets
right-truncation for free.

tapecheck's `lower_and_delete` is the same *idea* done the expensive
way: it lowers by **one** and then hunts for a deletable block, `j` over
the whole stream and `k` over 1..4. On a 200-choice tape, `n = 55 -> 1`
costs 54 lowerings each paying a search, and a lowering that drops more
than four choices cannot be expressed at all.

## What was actually missing, and what was not

Right-truncation was **already free**: an accepted candidate is
`out.Tape.image`, what the replay consumed (`tape.ml`'s `finish` returns
`Array.sub s.written 0 s.wlen`), so surplus trailing choices vanish by
construction. What was missing is deletion from the **front** of the
element region, which is what walks a late failing element leftward.

The signal was also already there and simply discarded:
`search_candidate` threw away `out.Tape.image` whenever the proposal was
uninteresting. It is now retained in `s_last_recorded`, and
`minimize_integer`'s `try_value` does the repair.

One bug worth recording, because it produces plausible garbage rather
than an error: `attempt` returns `false` both for "replayed and was not
interesting" and for "already seen, not replayed at all". Reading the
consumed length without clearing it first sizes the deletion from
whatever unrelated replay happened to run last. It is cleared before
every attempt.

## The measurement: it is inert, and the reason is pass order

Instrumented over 100 lengthlist trials, the repair fires **once**.

`minimize_integer` skips a choice already at its target, and in the
stock sweep `lower_and_delete` runs first and has already ground the
length prefix down one step at a time before `minimize_choices` ever
sees it.

Hoisting the lowering earlier does close lengthlist — and costs
`test_poison`:

| | stock order | `minimize_choices` first |
|---|---|---|
| **repair off** | lengthlist 73/100, 256 calls · poison 10/34 | lengthlist 7/100, 311 calls · poison **6/34** |
| **repair on** | lengthlist 74/100, 256 calls · poison 10/34 | lengthlist **100/100, 135 calls** · poison **6/34** |

Read the bottom-left and top-right cells together. The repair alone is
harmless and useless; the reorder alone is harmful and useless. Only
together do they close lengthlist, and the harm is unchanged.

So the poison regression is **not caused by the repair** — it is caused
by accepting bare lowerings early, and it is the same 6/34 with the
repair switched off.

Two further variants, both rejected:

- A dedicated integers-only repair pass in the same early slot measured
  identically (100/100 at 135, poison 6/34), confirming the damage is
  the position rather than the pass.
- A version that *probes* a lowering without accepting it, so only
  repaired proposals are ever taken, was worse on every axis: lengthlist
  76/100 at 373 calls, poison still 6/34, and the poison base tree
  drifted from 34 testable positions to 36.

## What ships

The mechanism, in `minimize_integer`, with the stock pass order. All ten
regression guards pass, `test_poison` is at 10/34 with its 34 positions
intact, and the full suite is green. lengthlist is 74/100 at 256 calls
against a 73/100 baseline — i.e. unchanged within noise.

Shipping an inert mechanism is a deliberate call: it is measured
harmless, it is the correct move, and the blocker is now a named and
quantified ordering problem rather than a missing capability.

## What would unblock it

The open question is an ordering — or an interleaving — under which the
length prefix is lowered in one jump *before* `lower_and_delete` grinds
it down, without granting every other integer the same early treatment.
`test_poison` is the constraint to satisfy, and 6/34 versus 10/34 is the
number to beat.

Worth noting what this is *not*: it is not a span problem. The ablation
above rules that out, so `sort_siblings` and the span work are not the
route here.

---

# Follow-up: the computed repair inside `lower_and_delete`

Branch `computed-repair`. **Not on master: it fails two cost guards.**

The 2x2 above concluded the blocker was pass order, and that hoisting
the lowering earlier closes lengthlist but costs `test_poison`. This
tries the third option: keep the pass order exactly as it is, and give
`lower_and_delete` the *computed* deletion size at its existing position
instead of searching for it.

It never accepts a bare lowering — that is what damaged poison. It
probes one to learn how many choices the replay consumed, then attempts
only the repaired proposal.

## Measured, n = 1000 paired

The first version of this table was n=100 with no variance quoted,
which cannot distinguish a real effect from noise. Redone properly:
**1000 independent random seeds** (master seed 20260802, recorded in
`~/prog/tapecheck-bench/seeds.txt`), the *same* seed list under both
arms so every comparison is within-seed, one worktree per arm.
Wilson intervals for rates, McNemar on the paired disagreements,
bootstrap CI (20 000 resamples) for the paired mean call difference.

| property | arm | fully minimal | 95% CI | mean calls | median | IQR |
|---|---|---|---|---|---|---|
| lengthlist | master | 719/1000 | 69.0–74.6% | 266.0 | 159 | 119–584 |
| lengthlist | **repair** | **990/1000** | **98.2–99.5%** | **126.6** | 130 | 82–173 |
| bind | master | 1000/1000 | 99.6–100% | 50.6 | 50 | 33–69 |
| bind | repair | 998/1000 | 99.3–99.9% | 80.0 | 79 | 45–114 |
| deep bind | master | 1000/1000 | 99.6–100% | 140.7 | 142 | 86–194 |
| deep bind | repair | 1000/1000 | 99.6–100% | 273.4 | 248 | 136–370 |
| listlen *(control)* | master | 1000/1000 | 99.6–100% | 148.3 | 150 | 145–152 |
| listlen *(control)* | repair | 1000/1000 | 99.6–100% | 149.3 | 151 | 146–153 |
| listsum *(control)* | master | 1000/1000 | 99.6–100% | 91.2 | 104 | 88–113 |
| listsum *(control)* | repair | 1000/1000 | 99.6–100% | 92.0 | 105 | 89–114 |

Paired differences (repair − master):

| property | quality | mean calls |
|---|---|---|
| **lengthlist** | 279 repair-only wins vs 8 master-only, **McNemar p = 8.6e-72** | **−139.3 [−152.0, −126.9]** |
| bind | 0 vs 2, p = 0.5 (not significant) | **+29.4 [+28.0, +30.8]** |
| deep bind | no disagreements | **+132.7 [+123.9, +141.7]** |
| listlen | no disagreements | +1.0 [+1.0, +1.0] |
| listsum | no disagreements | +0.8 [+0.7, +0.8] |

The lengthlist confidence intervals do not overlap and the effect is
about as unambiguous as this kind of measurement gets. The two cost
regressions are equally real — both intervals are far from zero — and
the two controls move by one call, which is the probe being paid once
and is the right order of magnitude for a change that should not touch
them.

Suite-level figures, n as built in: `test_poison` 10/34 → **12/34**,
`test_poison_lists` 22/48 → 20/48, `test_shrink_quality` 5/8 → 5/8.
Those are single runs over fixed case sets, so treat them as
indicative rather than measured; the 1000-seed table above is the
evidence.

### Two methodology errors worth recording

**The first table was n=100 with no variance.** Matthias caught it. The
direction survived (71.9% vs 99.0% brackets the 73 vs 99), but nothing
in that table justified believing it.

**My first 1000-seed run measured the wrong property.** I wrote a
`bind` from memory — `len in 1..10`, elements `0..100` — and it
reported a paired difference of −0.2 calls [−2.0, +1.7], i.e. "no
effect". The guard's actual bind is `len in 1..64` with elements
`0..1000`. With the real property the answer is +29.4 [+28.0, +30.8].
A confident null result about a property nobody was asking about.
The bench now copies the guard's definitions verbatim, including
`count = 200`.

lengthlist goes from a recorded frontier to one case short of
Hypothesis, at half the cost, and poison improves — the reorder made
poison *worse*, so the "keep the order" hypothesis was right.

## Why the cost rises, and why the obvious fixes do not work

The probe costs one evaluation whether or not it finds anything. Three
attempts to avoid paying it, all measured, all with no effect on the
numbers:

1. **A greedy repeat** after each success, matching the search path's.
   Identical results — the loop rarely fires twice.
2. **Earned probing** (spend 8 probes finding out whether the move pays
   here, then stop). Identical, because the cap never binds: the repair
   *does* succeed on bind, so it keeps its probe.
3. **Making it a fallback** after the j/k search fails. This fixes the
   cost completely — bind 53, deep bind 142, all guards green — and
   loses the entire gain, lengthlist back to 73/257. The fallback never
   fires there because the search *does* succeed, just slowly.

(3) is the one that explains the whole thing. On ordinary shapes the
deletable block sits at `j = i+1` and the existing search finds it in
**one** attempt; probing first spends two where one sufficed. The
computed repair only wins where the search is slow or cannot express
the deletion at all — further than the scan reaches, or larger than the
`k <= 4` cap — which is exactly lengthlist. The two are not orderable:
whichever goes first pays for the other.

## The decision this needs

Raising two cost bounds — bind 74 → ~90, deep bind 210 → ~280 — buys
lengthlist 73 → 99 and poison 10 → 12, and costs `test_poison_lists`
22 → 20.

Arguments for: the increases are 1.5-1.8x, where the regressions those
guards were built for were 3-20x (galloping took bind to 984), so both
would still catch their named failure at the higher bound. lengthlist's
own cost halves.

Argument against, and it is the repo's own standing warning: several
past changes looked obviously correct, held quality at 100/100, and
blew cost up 3-20x — which is precisely why cost is guarded at all.
Raising a cost bound to admit a change is the move that rule exists to
make deliberate.

Not landed. Needs a call.

---

# Resolved: v3 lands it, with no bound raised

The trade in the section above was not intrinsic. Two further
measurements dissolved it.

## v2 — fall back after ONE cheap attempt, not after the whole search

The instrumented run explained the cost precisely. On bind the repair
fires 32 times per run and **succeeds 31 of those** — it was never
failing, it was *redundant*: the deletable block sits at `j = i+1` and
the existing search finds it in one attempt, so the probe added about
one call each time (slope +0.99 calls per probe, r = 0.85).

Falling back after the *full* j/k search had already been tried and was
useless — it fixed the cost and lost the whole gain. Falling back after
a *single* cheap attempt (lower a step, delete the one choice after it)
is the different thing: cheap enough not to matter when it misses,
and it catches exactly the case that made the probe redundant.

Probes per run collapsed: lengthlist 50.5 → 8.0, bind 32.3 → 1.2,
deep bind 103.9 → 2.4.

## v3 — the repair must not run on tapes with sub-streams

v2 broke something the guards nearly missed: `test_fn_shrink`'s
orphan-adoption property, which asserts `stuck = 0` over 40 seeds, hit
1. At n=40 against a strict zero that could be luck, so it was measured
at n=1000: master **0/1000** (0.00–0.38%), v2 **19/1000** (1.22–2.95%),
McNemar p < 0.0001. Real.

v1 scored an identical 19/1000, which exonerates the cheap deletion and
convicts the repair itself. The mechanism follows: the deletion is
sized from how many choices *this stream* consumed, and that arithmetic
stops describing the proposal once sibling streams exist. A generated
function keys its observed stream by the argument's hash, so lowering
the argument re-keys it and the engine must adopt the orphan — deleting
a computed block at the same moment moves the ground under that.

Restricting the repair to single-stream tapes restores **0/1000**.
lengthlist has no sub-streams and does not notice.

## Final, n = 1000 paired, master vs v3

| property | master minimal | v3 minimal | master calls | v3 calls | paired call diff |
|---|---|---|---|---|---|
| **lengthlist** | 719/1000 (69.0–74.6%) | **994/1000 (98.7–99.7%)** | 266.0 | **84.1** | **−181.9 [−194.2, −169.7]** |
| bind | 1000/1000 | 1000/1000 | 50.6 | 49.0 | −1.6 [−2.1, −1.0] |
| deep bind | 1000/1000 | 1000/1000 | 140.7 | 171.9 | +31.2 [+25.2, +37.5] |
| listlen *(control)* | 1000/1000 | 1000/1000 | 148.3 | 149.3 | +1.0 |
| listsum *(control)* | 1000/1000 | 1000/1000 | 91.2 | 92.0 | +0.8 |

lengthlist: 280 v3-only wins against 5, **McNemar p = 5.0e-76**.

**Generation is untouched.** `never found the bug` is 0 in every cell of
every arm — this only ever changes the shrink phase, which is the half
where spending time is cheap.

Suite level: every regression guard passes with **no bound raised**
(bind 51 against 74, deep bind 179 against 210, lengthlist 99/100 at 85
calls against 73/100 at 257). `test_poison` 10/34 → **12/34**,
`test_poison_lists` 22/48 → 21/48, `test_shrink_quality` 5/8 → 5/8,
orphan 0/1000, full suite green.

The only remaining cost is deep bind at +31 calls for identical quality.

## What the three rounds cost, and what they were worth

Each variant was a measurement, not a guess, and each one falsified the
previous explanation:

1. **v1** established the effect is real and that the cost is not
   avoidable by patience heuristics (a greedy repeat and an
   earned-probing cap both changed nothing).
2. **Instrumentation** showed the repair was redundant rather than
   failing on the cheap shapes — which is what made v2 obvious.
3. **The n=1000 orphan sweep** caught a quality regression that the
   suite reported as a single stuck seed out of 40, which is not enough
   to act on either way.

The third is the one worth remembering. A strict `= 0` assertion over
40 draws cannot tell "slightly worse" from "unlucky", and the honest
response to it is a bigger sample rather than a judgement call.

---

# CORRECTION: the quality win is a one-line bookkeeping fix, not the repair

Everything above attributes lengthlist's improvement to the computed
repair. **That is wrong**, and a skeptic pass caught it after the change
had already been merged. The numbers in the tables are all real; the
causal account attached to them was not.

## What the ablation showed

v2 added two things at once and only one was ablated. Doing the other:

| configuration | lengthlist | mean calls |
|---|---|---|
| master | 719/1000 (69.0–74.6%) | 266.0 |
| cheap single delete only, probe OFF | **987/1000 (97.8–99.2%)** | 150.5 |
| probe only (v1) | 990/1000 | 126.6 |
| both (v3) | 994/1000 | 84.1 |

Paired, the probe on top of the cheap delete is **12 wins to 5,
McNemar p = 0.14 — not significant**. The cheap delete on top of master
is **268 to 0, p = 4.2e-81**. The probe buys cost (−66 calls), not
quality.

## Three explanations of mine, all falsified

The cheap delete's proposal is *identical* to the k/j search's first
candidate (k=1, j=i+1), so on the face of it it cannot change anything.

1. *"It makes successful steps cheaper, so the budget lasts."*
   `attempt_batch`'s non-pool path short-circuits on first success, so
   the success already cost one evaluation. Refuted by reading it.
2. *"It escapes the per-pass failure cutoff."* Putting it back under
   `live ()` changed nothing — 994/1000 and 84.1 calls, identical.
   Refuted by measurement.
3. *"The deletion is sized per-stream, so sibling streams break it."*
   Never tested. That sentence was inference written into a code
   comment as if it were a finding.

## The actual mechanism

Found by an independent refutation pass (headless `codex`, a different
model family) after those three failed.

The greedy repeat that runs after a batch success re-applies the same
edit until it fails — and **never incremented `lad_successes`**. So a
run of N accepted deletions at one position banked ONE patience credit.
Since

    live () = consecutive_failures < max_pass_failures + lad_successes

the pass was starved of patience in exactly the situation where it was
being most productive. The "cheap attempt" reached the correct state by
accident: it accepted one edit, restarted the scan at `i := 0`, and so
passed through the increment once per edit.

Confirmed rather than merely made plausible: moving the increment into
the greedy repeat, on plain pre-change master with no other edit,
reproduces the cheap-delete result **to the decimal on all five
properties** — 987/1000 at 150.5, 50.9, 178.1, 148.3, 91.2.

## What ships, and why each piece is there

- **The credit in the greedy repeat** — the actual fix. One increment.
  Zero measured cost; the configuration with and without it is
  bit-identical today, because the cheap attempt below already banks
  per edit. Kept anyway, so the invariant holds on its own rather than
  as a side effect of another block.
- **The single cheap attempt** — kept on its real merit: it accepts the
  common deletion in one evaluation where the probe needs two. Removing
  it costs lengthlist 994 → 990 and 84.1 → 126.6 calls.
- **The computed repair (probe)** — kept for cost on the shapes the
  search handles badly: −66 calls on lengthlist, −6 on deep bind, −2 on
  bind, +1 on the controls. It buys no significant quality.
- **The single-stream restriction** — kept: without it the orphan
  property goes 0/1000 → 19/1000 stuck (p < 0.0001). Note this is the
  one place where the per-stream reasoning IS backed by measurement,
  even though the mechanism story remains inference.

## The lesson

The change was measured at n=1000 with confidence intervals and paired
tests, and the headline numbers were all correct — and the explanation
was still wrong, because **no measurement was ever pointed at the
attribution itself**. Ablate every component you add, not just the one
you find interesting; and when two or three of your own mechanisms have
been falsified in a row, stop generating a fourth and get an outside
opinion.

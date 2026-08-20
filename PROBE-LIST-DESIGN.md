# The continuation-list probe: what it separates, and what it does not

Initial run 2026-08-20 on `1ebd6a7`, OCaml 5.3.0. Its
[raw output and provenance](probe_list_design/results/2026-08-20-initial.md)
are tracked beside the source in `probe_list_design/probe_list_design.ml`.

The missing-cell follow-up ran on the same date and switch. Its tracked raw
output, predeclared analysis, and provenance are in
`probe_list_design/results/2026-08-20-interleaved-budget.{md,txt}`.

This probe exists to decide PR #29. #29 rewrote Base's list size
allocation to be monotone in the length, and paid for it with a changed
distribution and a loosened size bound. The question the probe answers is
whether a Hypothesis-shaped list -- per-element continuation booleans --
buys the same monotonicity without that bill.

## The arms are not one design, they are two independent axes

Reading the arms as a ladder of increasingly-Hypothesis-like designs is
wrong, and it is the reading that makes the results look contradictory.
There are two axes. The initial probe crossed three of their four cells; the
tracked follow-up now measures the fourth.

**Axis A -- how the length is decided.** A log-uniform integer (`stock`,
`length-int`, `running`) versus a run of continuation booleans
(`continuation`, `continuation+span`).

**Axis B -- how element size is allocated.** A running budget split
across elements, bounded by `size` (`stock`, `running`, `continuation`,
`cont+span+bud`), versus handing every element the ambient `size` independently
(`continuation+span`, which drops the budget deliberately, to isolate the
structural question -- see the comment on `list_continuation_spans`).

The missing cell was continuation spans *with* a running budget. Its result is
reported at the end: the straightforward online budget restores the bound and
retains strong minima, but changes the length distribution and is not
shippable as measured.

## What the probe establishes

**The distribution objection to #29 does not apply to continuation
lengths.** Raw lengths at size 10 over 20k samples: stock mean 3.591,
continuation 3.579, continuation+span 3.599, two-sample chi-square 7.68
across 11 bins. Choosing the length by unary continuation booleans
reproduces stock's length distribution. This was the axis-A worry and it
is answered.

**Continuation booleans on their own are worse than a length integer.**
`continuation` decides the whole length up front and only then generates
elements, so a boolean and the element it nominally guards are not
adjacent on the tape. Deleting one shortens the list without moving the
element draws. Minimality over 100 seeds: on `sum >= 100` it reaches the
minimum 54 times against stock's 100, with non-minima like `[0; 0; 100]`
-- exactly the desynchronisation signature. On `length >= 3` it is 92
against 100.

**The combined `continuation+span` arm is the best measured.** It puts
each boolean and the element it guards inside one deletable span, so a
span deletion removes both -- and it also drops the budget. Both changes
at once, so what follows is that arm's result, not an attribution:

| arm | choices/element | `len>=3` | `sum>=100` | `hd=length` |
|---|---|---|---|---|
| stock | 4.82 | 100, 151 att | 100, 94 att | 47, 134 att |
| length-int | 2.45 | 100, 201 att | 99, 51 att | 74, 104 att |
| continuation | 3.15 | 92, 108 att | 54, 114 att | 46, 84 att |
| continuation+span | **2.28** | 100, **41 att** | 100, **25 att** | **99**, **13 att** |

`hd = length` is the subject the pairwise-witness suite independently
flagged as this engine's worst case: 235 certificates, all of them on
that predicate, 7 distinct end states against 1 for every other subject.
The `+span` arm takes it from 47/100 to 99/100 and from 134 shrink
attempts per failure to 13.

Which of the two simultaneous changes bought that is **not established
here**. Interleaving is the plausible mechanism -- `continuation`'s
non-minima are exactly the desynchronisation signature, and spans are what
remove it -- but ambient sizing changes both the values generated and the
tape structure, so the comparison is confounded. The prediction section
below is how to settle it.

Recursive trees, 50 seeds, fail at 20 nodes: stock hits the exact
20-node minimum 14 times with worst case 50 nodes and 2081 attempts;
`cont+span capped` hits it 50 times, worst case 20, 154 attempts.

## What the probe does not establish, and the number that says so

`cont+span str` -- a list of strings at size 50 -- has mean 479.49
characters and max 2179. The contract is 50. That is a 43x breach, and it
is the single result that makes the `+span` arm unshippable as measured.

It is *not* caused by spans or by continuations. Same axis A, budget
restored: `continuation str` is mean 20.19, max 50. `running str` is mean
20.40, max 50. `stock strings` is mean 27.03, max 50. Every budgeted arm
respects the bound; the one unbudgeted arm does not. The breach is axis
B, and axis B was dropped on purpose.

The same cause is the likely explanation for the leaf-cap cost, though
both figures need reading carefully. `leaf_cap_stats.retries` accumulates
retry *attempts*, not draws that retried, so 15820 over 20000 executions
is **0.791 attempts per draw**, not "four draws in five" -- and with
`max_retries` at 9, some draws retried many times while others never did.
The 20000 is also two 10000-sample passes over the *same* seeds, so it is
10000 independent draws counted twice, not 20000 observations. The number
that would actually settle it -- draws with at least one retry -- is not
instrumented.

The recording cost is the sharper figure. Mean choices 119.41 is
`count_choices out.image`, the whole image; the 102.96 "discarded" is a
**subtotal of that same number**, not a separate quantity. So roughly
**16.45 choices are live and 102.96 are inside abandoned attempts** --
86% of the recording is retry debris. Our
`recursive_with_max_leaves` is a faithful port of Hypothesis's
`RecursiveStrategy` -- shared leaf counter, bounded tower of `extend`
applications (`while 2 ** (len(strategies) - 1) <= max_leaves`), retry
the whole draw from the advanced stream on `LimitReached`
(`hypothesis-python/src/hypothesis/strategies/_internal/recursive.py`,
6.152.9). So the retry rate is not a porting error. In Hypothesis the
tower bounds depth and the cap is a rare backstop; here it fires on four
draws in five, which is what an unbudgeted `extend` would do to it.

## The predeclared prediction, and what would refute it

The claim above is that axes A and B are separable: that interleaved
continuation spans deliver the shrink-quality wins, and that a running
budget can be put back underneath them without losing those wins.

If that is right, an arm crossing the missing cell -- interleaved
deletable continuation spans, elements drawn from a running budget as in
`generate_elements` -- shows all three of: string tail max back to 50,
leaf-cap retry rate far below 79%, and minimality and attempt counts
close to the `continuation+span` row above.

If instead minimality falls back toward the `continuation` row when the
budget is restored, then the budget was load-bearing for the wins, the
axes are not separable, and the trade-off #29 identified is real rather
than an artefact of how the arms were built. That is the observation to
check, and it is one arm's worth of work in a probe that already has
every piece.

## Missing-cell result: bounded, but not distribution-preserving

The follow-up implements the direct online crossing cell. Each continuation
and guarded element share a deletable span. A continued element first pays one
unit of structural budget, then receives a log-uniform share of the remaining
budget. If no budget remains, the next continuation is forced to stop.

This restores both safety properties decisively. At size 50, total string
length has mean 22.14 and maximum 50, compared with mean 479.49 and maximum
2,179 for the unbudgeted span arm. The capped recursive generator records zero
retry attempts over 20,000 successful tail measurements and again zero over
1,000 separately taped draws; the unbudgeted arm records 15,820 and 720.

The integer-list minima remain near the unbudgeted span arm:

| arm | `len>=3` | `sum>=100` | `hd=length` |
|---|---|---|---|
| continuation+span | 100/100, 41 att | 100/100, 25 att | 99/99, 13 att |
| cont+span+bud | 100/100, 208 att | 99/100, 33 att | 100/100, 56 att |

Thus interleaving and spans, rather than an unbounded ambient element size,
account for the exact-minimum improvement on these cases. The efficiency
prediction is refuted: the budgeted arm takes substantially more shrink
attempts. Recursive quality shows the same split -- both span arms reach the
exact 20-node minimum for all 50 seeds, but the budgeted arm takes 851 attempts
per failure against 154.

The decisive new failure is distributional. At size 10, raw mean list length
falls to 1.956, versus 3.591 for stock and 3.599 for the unbudgeted span arm.
The positive-control predicate requiring ten strings is not reached at all in
100 seeds of 200 cases. Because an early element can consume budget that a
later continuation would need for its structural charge, an online running
budget makes later continuation less likely even though the continuation
probabilities themselves are unchanged.

So the two axes are separable for the measured exact minima and safety bound,
but not for distribution or shrink cost under this straightforward encoding.
This arm does not supersede PR #29. A shippable design must either know how
much structural budget to reserve before allocating element sizes, or adopt
and document a different size/distribution contract.

## Predeclaration: payload-only running budget

The next arm tests the second option explicitly. It keeps the interleaved
continuation/span representation and its unchanged conditional length law,
but charges the running budget only for element payload sizes. List nodes do
not consume that same budget. Therefore the proposed contract is:

- list length is at most `size`;
- the sum of element size parameters is at most `size`; and
- counting both list nodes and recursively generated payload as one quantity
  may reach `2 * size`, rather than Base's current `size` bound.

This is a different contract, not an attempt to preserve Base's exact size
semantics. The question is whether that documented relaxation removes the
online-budget arm's length bias without returning to the unbudgeted arm's
explosive nested generation.

The primary estimands and stopping rules are fixed before implementation:

- raw and taped list-length distributions at size 10 over the existing 20,000
  deterministic seeds;
- aggregate string length at size 50 over 10,000 seeds;
- leaf-cap retry attempts over the existing 20,000 successful generation-tail
  draws and 1,000 separately taped draws;
- exact-minimum frequency and attempts per found failure on the four existing
  100-seed flat cases; and
- exact 20-node minima and attempts per failure over the existing 50 recursive
  seeds.

The experimental unit is a seed. Arms remain paired by seed in one process;
compiler, runtime state, generator code outside the new arm, and the fixed
size/count settings are nuisance factors. The existing stock, unbudgeted-span,
and structurally budgeted arms remain unchanged controls. The ten-string case
is the reachability positive control.

The arm is promising enough for a production follow-up only if all of these
hold: its raw mean length is within 0.05 of stock; maximum aggregate string
length is at most 50; leaf-cap retries are below 0.1 per successful draw;
each reachable flat case is within five exact minima of the unbudgeted span
arm; flat and recursive attempts per failure are at most twice that arm; and
the ten-string failure is found in at least 90 of 100 seeds. Failing any one
criterion is retained as a negative result. The complete probe is run twice;
byte-identical stdout is the determinism check. These thresholds are design
screens, not population-level statistical claims.

## Payload-only budget result: reachability restored, candidate rejected

The complete result and raw deterministic output are retained under
`probe_list_design/results/2026-08-20-payload-budget.{md,txt}`. The arm fails
its predeclared production screens.

Raw mean length returns to 3.642 (stock 3.591), and the ten-string failure is
again found in 100/100 seeds. Capped recursive generation records no retries in
20,000 generation-tail draws or 1,000 separately taped draws. Those observations
confirm the mechanism: it was charging future list nodes from the same online
budget, not continuation probabilities themselves, that suppressed length.

The relaxed budget does not preserve the earlier aggregate-string bound:
maximum total length is 78 at size 50. Base's string generator may produce
`element_size + 1` characters, so omitting one structural charge per list
element changes the realised aggregate bound from `size` to `size + length`.
That is consistent with the declared `2 * size` combined contract, but fails
the fixed at-most-50 screen.

The quality/cost trade-off also remains. Exact minima are 100/100 for
`length >= 3`, 100/100 for `sum >= 100`, and only 75/98 found failures for
`hd = length`; attempts per failure are 219, 37, and 96. Recursive exact minima
remain 50/50, at 605 attempts per failure. The unbudgeted span arm was 100/100
at 41, 100/100 at 25, 99/99 at 13, and 50/50 recursive at 154. Thus this arm
restores distributional reachability and bounds growth, but does not retain
the main structural arm's shrink efficiency or hardest-case quality. It is not
a production candidate and does not supersede PR #29.

The two negative budget arms also close the apparent middle ground. If every
length through `size` must remain possible, list nodes and element payload share
one hard bound, and each element is generated before the next continuation is
known, reserving for the possible all-continue suffix forces every online
element allocation to zero. The proof and the remaining architectural escape
routes are in `design/continuation-budget-trilemma.md`.

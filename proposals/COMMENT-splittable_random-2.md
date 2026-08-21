# Draft status comment for `janestreet/splittable_random#2`

Do not post without Matthias's approval. This corrects the public record; it is
not a ping, and it deliberately does not ask for immediate action.

Publication prerequisite satisfied 2026-08-21: the product and companion
evidence repositories are public, and every link below is immutable.

---

A factual update while this is on the back burner: continued work on Tapecheck
has produced a stronger inactive-cost result and exposed one missing part of
this diff's contract.

First, I replaced my earlier minimum-of-five timing with a predeclared
same-body experiment which isolates the production inactive observer check.
That [first 40-pair result](https://github.com/matthiasgoergens/tapecheck-evidence/tree/ade578a729359dfcc954320089a5cde7207e62a8/experiments/intercept-overhead/2026-08-21-f4c7634-bound)
found a real cost and exposed an avoidable wrapper/default-call boundary. I
removed that boundary and ran a [separately predeclared 60-pair
confirmation](https://github.com/matthiasgoergens/tapecheck-evidence/tree/ade578a729359dfcc954320089a5cde7207e62a8/experiments/intercept-overhead/2026-08-21-b454796-optimised).
All three primitive-loop screens passed their familywise-95% upper-bound rule:
Boolean, bounded integer, and float point estimates were 0.9930, 1.0063, and
1.0190, with upper bounds of 1.0014, 1.0162, and 1.0255. The narrow claim is
therefore less than 5% inactive overhead for these loops on this host and
OCaml 5.3.0—not zero cost or general end-to-end equivalence. All 1,080
confirmation arm observations are retained, as is the negative first result.

Second, the current engine now [tests generated functions end to
end](https://github.com/matthiasgoergens/tapecheck/blob/81051e5388612e98f927f9552b7abc1654b2fa6c/test_bq/test_fn_shrink.ml).
That requires split and perturbed child states to receive keyed observers;
notifying the parent while leaving the child hook-free, as this v1 diff does,
cannot record the function body's choices. The tested local contract has
`on_split` and `on_perturb` return the observer for the resulting state, with
the perturb salt included.

The newer *Fail Faster* artifact also gave me a separate performance boundary.
Tapecheck itself does not require C; the artifact's AllegrOCaml implementation
offers an optional C implementation of the Splittable-random algorithm for
faster generation, and that path bypasses ordinary `Splittable_random` calls.
Wrapping
every primitive in OCaml dispatch was [materially slower in two controlled
batches](https://github.com/matthiasgoergens/tapecheck-evidence/tree/ade578a729359dfcc954320089a5cde7207e62a8/experiments/fast-backend-dispatch/2026-08-20-5035e8d),
while testing observer activity once and selecting a complete direct or
observed loop [met a predeclared ±2% equivalence margin in both
batches](https://github.com/matthiasgoergens/tapecheck-evidence/tree/ade578a729359dfcc954320089a5cde7207e62a8/experiments/fast-backend-selection/2026-08-20-299a7a7).
I have since [implemented that dual path against the pinned BER MetaOCaml
source](https://github.com/matthiasgoergens/tapecheck-evidence/tree/ade578a729359dfcc954320089a5cde7207e62a8/experiments/fail-faster-dual/2026-08-20-69d843f)
and backported the observer seam to its v0.16 dependency. Behavioural smoke
tests pass. In the [first actual staged integer-list
timing](https://github.com/matthiasgoergens/tapecheck-evidence/tree/ade578a729359dfcc954320089a5cde7207e62a8/experiments/fail-faster-dual-performance/2026-08-20-69d843f),
dual inactive / direct C was 0.9898 with a paired 90% interval of
0.9750–1.0022, so it did **not** meet the predeclared ±2% equivalence
criterion. A [24-block, four-workload
replication](https://github.com/matthiasgoergens/tapecheck-evidence/tree/ade578a729359dfcc954320089a5cde7207e62a8/experiments/fail-faster-dual-multi/2026-08-20-69d843f)
retained all 192 observations: Boolean and integer-list familywise intervals
fit the margin, while Boolean-list and nested-list intervals did not. Blanket
equivalence and end-to-end artifact throughput therefore remain open.

I do not propose silently growing this public record with all of Tapecheck's
later weighted-choice and structural-span experiments. If you return to the
design, my suggestion is to treat this PR as the Wave 1 discussion and decide
whether you would prefer a smaller replacement with an abstract observer,
correct split/perturb propagation, and the corrected performance boundary.
The structural generator seam should follow as a separate proposal: opt-in
first for migration safety, with the measured path towards future defaults.

No action needed now; I wanted the limitations recorded before pointing the
paper authors or other reviewers at this thread.

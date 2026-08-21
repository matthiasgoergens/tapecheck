# Draft status comment for `janestreet/splittable_random#2`

Do not post without Matthias's approval. This corrects the public record; it is
not a ping, and it deliberately does not ask for immediate action.

Publication prerequisite satisfied 2026-08-21: the product and companion
evidence repositories are public, and every link below is immutable.

---

A factual update while this is on the back burner: continued work on Tapecheck
has invalidated one claim I made above and exposed one missing part of this
diff's contract.

First, please treat my earlier minimum-of-five performance numbers as
withdrawn. I replaced that benchmark with [two separately predeclared,
randomised fresh-process batches](https://github.com/matthiasgoergens/tapecheck-evidence/tree/c7180809729f336cc1f69d53744b60d37f7928ee/experiments/intercept-overhead/2026-08-20-d436c9a).
The Boolean and bounded-integer conclusions change between batches, so those
measurements establish neither equivalence nor a stable overhead for the unused
seam. I do not currently have adequate evidence for “no measurable cost”.

Second, the current engine now [tests generated functions end to
end](https://github.com/matthiasgoergens/tapecheck/blob/81051e5388612e98f927f9552b7abc1654b2fa6c/test_bq/test_fn_shrink.ml).
That requires split and perturbed child states to receive keyed observers;
notifying the parent while leaving the child hook-free, as this v1 diff does,
cannot record the function body's choices. The tested local contract has
`on_split` and `on_perturb` return the observer for the resulting state, with
the perturb salt included.

The newer *Fail Faster* artifact also gave me a clearer performance boundary.
Its fastest C backend bypasses ordinary `Splittable_random` calls. Wrapping
every primitive in OCaml dispatch was [materially slower in two controlled
batches](https://github.com/matthiasgoergens/tapecheck-evidence/tree/c7180809729f336cc1f69d53744b60d37f7928ee/experiments/fast-backend-dispatch/2026-08-20-5035e8d),
while testing observer activity once and selecting a complete direct or
observed loop [met a predeclared ±2% equivalence margin in both
batches](https://github.com/matthiasgoergens/tapecheck-evidence/tree/c7180809729f336cc1f69d53744b60d37f7928ee/experiments/fast-backend-selection/2026-08-20-299a7a7).
I have since [implemented that dual path against the pinned BER MetaOCaml
source](https://github.com/matthiasgoergens/tapecheck-evidence/tree/c7180809729f336cc1f69d53744b60d37f7928ee/experiments/fail-faster-dual/2026-08-20-69d843f)
and backported the observer seam to its v0.16 dependency. Behavioural smoke
tests pass. In the [first actual staged integer-list
timing](https://github.com/matthiasgoergens/tapecheck-evidence/tree/c7180809729f336cc1f69d53744b60d37f7928ee/experiments/fail-faster-dual-performance/2026-08-20-69d843f),
dual inactive / direct C was 0.9898 with a paired 90% interval of
0.9750–1.0022, so it did **not** meet the predeclared ±2% equivalence
criterion. A [24-block, four-workload
replication](https://github.com/matthiasgoergens/tapecheck-evidence/tree/c7180809729f336cc1f69d53744b60d37f7928ee/experiments/fail-faster-dual-multi/2026-08-20-69d843f)
retained all 192 observations: Boolean and integer-list familywise intervals
fit the margin, while Boolean-list and nested-list intervals did not. Blanket
equivalence and end-to-end artifact throughput therefore remain open.

I do not propose silently growing this public record with all of Tapecheck's
later weighted-choice and structural-span experiments. If you return to the
design, my suggestion is to treat this PR as the Wave 1 discussion and decide
whether you would prefer a smaller replacement with an abstract observer,
correct split/perturb propagation, and the corrected performance boundary.
The structural generator seam can remain a separate proposal.

No action needed now; I wanted the limitations recorded before pointing the
paper authors or other reviewers at this thread.

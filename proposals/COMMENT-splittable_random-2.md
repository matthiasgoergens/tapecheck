# Draft status comment for `janestreet/splittable_random#2`

Do not post without Matthias's approval. This corrects the public record; it is
not a ping, and it deliberately does not ask for immediate action.

Publication prerequisite: push the product and companion evidence repositories,
then add immutable links for the unused-seam, fast-dispatch, and fast-selection
and dual-generated experiments before posting. The prose below intentionally
contains no moving or currently unpublished evidence URL.

---

A factual update while this is on the back burner: continued work on Tapecheck
has invalidated one claim I made above and exposed one missing part of this
diff's contract.

First, please treat my earlier minimum-of-five performance numbers as
withdrawn. I replaced that benchmark with two separately predeclared,
randomised fresh-process batches. The Boolean and bounded-integer conclusions
change between batches, so those measurements establish neither equivalence
nor a stable overhead for the unused seam. I do not currently have adequate
evidence for “no measurable cost”.

Second, the current engine now tests generated functions end to end. That
requires split and perturbed child states to receive keyed observers; notifying
the parent while leaving the child hook-free, as this v1 diff does, cannot
record the function body's choices. The tested local contract has `on_split`
and `on_perturb` return the observer for the resulting state, with the perturb
salt included.

The newer *Fail Faster* artifact also gave me a clearer performance boundary.
Its fastest C backend bypasses ordinary `Splittable_random` calls. Wrapping
every primitive in OCaml dispatch was materially slower in two controlled
batches, while testing observer activity once and selecting a complete direct
or observed loop met a predeclared ±2% equivalence margin in both batches.
I have since implemented that dual path against the pinned BER MetaOCaml
source and backported the observer seam to its v0.16 dependency. Behavioural
smoke tests pass. In the first actual staged integer-list timing, dual inactive
/ direct C was 0.9898 with a paired 90% interval of 0.9750–1.0022, so it did
**not** meet the predeclared ±2% equivalence criterion. End-to-end artifact
throughput remains open.

I do not propose silently growing this public record with all of Tapecheck's
later weighted-choice and structural-span experiments. If you return to the
design, my suggestion is to treat this PR as the Wave 1 discussion and decide
whether you would prefer a smaller replacement with an abstract observer,
correct split/perturb propagation, and the corrected performance boundary.
The structural generator seam can remain a separate proposal.

No action needed now; I wanted the limitations recorded before pointing the
paper authors or other reviewers at this thread.

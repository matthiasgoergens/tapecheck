# Published update on `janestreet/splittable_random#2`

Posted with Matthias's approval on 2026-08-21:
https://github.com/janestreet/splittable_random/pull/2#issuecomment-5368115169

---

I have revised the implementation and PR description in place.

One correction to my July comment: “no measurable cost” was too broad. Better
[experiments](https://github.com/matthiasgoergens/tapecheck-evidence/tree/outreach-2026-08-21/experiments/intercept-overhead)
found an avoidable cost in a generic helper used by Tapecheck; the direct
inactive path already used in this diff performed better. The follow-up
supports less than 5% overhead for the three measured primitive loops on the
test machine, not zero cost or a general end-to-end claim.

The revised contract also handles generated functions correctly: `on_split`
can supply an interceptor for the child state, and `on_perturb` receives the
salt and can replace the current interceptor. The updated tests cover both
behaviours.

There is no urgency to review this while it is back-burnered; I wanted the diff
and public performance claim to match the tested design before pointing other
reviewers at the thread.

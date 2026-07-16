# Draft reply to ceastlund on janestreet/splittable_random#2

Status: POSTED 2026-07-16 as
https://github.com/janestreet/splittable_random/pull/2#issuecomment-4989794609

---

Thanks for taking a look. These are fair concerns, so let me answer with some data and context.

**Performance when unused.** I measured the seam's cost by mechanically stripping it from the patched source and benchmarking the two libraries head to head (20M draws, min of 5 alternating reps, amd64, flambda2). Results in ns per draw, no-hook vs seam: bool 11.13 vs 11.23, int in 0..1000 15.77 vs 15.65, float in 0..1 11.34 vs 11.39. All deltas are within run-to-run noise (the int case comes out nominally faster with the seam). Two design choices keep it that way. First, the check is one load of an immutable field plus a compare against `None`, and since the field is `None` for every state not created by `with_intercept`, the branch is perfectly predicted in normal use. Second, only user-level draws are intercepted; the internal rejection loops (`next_int64`, the unbiased-remainder loop) are not, so a draw that internally consumes several PRNG steps pays the branch once, not per step.

**Why `Splittable_random` rather than a `Random` wrapper.** Not out of any preference for `Splittable_random` as a PRNG. The motivation is that `base_quickcheck`'s generators are typed against it: `Generator.generate : 'a t -> size:int -> random:Splittable_random.t -> 'a`. A wrapper around `Stdlib.Random` can only observe generators that draw through the wrapper, which would mean rewriting the generator corpus. The point of putting the seam here is that the existing ecosystem of ppx-derived and hand-written `base_quickcheck` generators becomes observable unchanged.

**Fit with `base_quickcheck`'s model of shrinking.** Agreed, it deliberately does not fit `Shrinker.t`; it replaces it for tests that opt in. The engine records the choice sequence during generation, shrinks by editing that recorded sequence, and re-runs generation to obtain the shrunken value. That makes shrinking work for every generator, including `filter` and `bind` compositions where value-level shrinkers struggle, and the shrunken value is always in the generator's range by construction. Hypothesis moved to this model ("internal shrinking") for the same reasons. There is a working engine at https://github.com/matthiasgoergens/tapecheck demonstrating it on unchanged `base_quickcheck` generators.

On the practical side, this PR is not blocking me: tapecheck currently vendors the patched `splittable_random` and that is sustainable. I opened it because the seam is small and the vendoring tax otherwise falls on anyone else who wants to build on the same idea. If the remaining concern is having the hooks in the core type at all, I see two alternatives worth exploring: (a) an arrangement where the dispatch only exists in states created for testing, for instance a functorised or two-constructor state so ordinary states carry no field at all, or (b) keeping the seam out of upstream and documenting the vendored patch as the supported route. Happy to go whichever way you prefer.

# Upstream PR: interception seam for splittable_random

Status: patch ready on branch `tape-hooks-v017` of the local clone at
~/prog/splittable_random-upstream (commit 1484725, based on the
v0.17.0 tag; builds clean and passes its inline tests on stock OCaml
5.3). NOT yet submitted; needs Matthias's approval, a fork push, and a
decision on target base (see Open questions).

## Draft PR title

Add an interception seam for property-testing engines

## Draft PR body

This adds an optional `Intercept` record to `Splittable_random.t`:
hooks for `int64`, `float`, `unit_float`, and `bool` (each receiving
the default sampler as a fallback), plus `on_split` and `on_perturb`
notifications. States without hooks, including everything the module
constructs itself, behave exactly as before at the cost of one branch
per draw; `split`-off states are hook-free.

The seam is small because of a nice property of this module's design:
`int`, `int32`, `int63`, `nativeint`, and all of `Log_uniform`
delegate to `int64`, so a single hook observes every bounded integer
draw together with its bounds.

Why: this is exactly the surface a Conjecture-style (Python
Hypothesis) choice-tape shrinker needs to give base_quickcheck
integrated shrinking with zero changes to generators, including
everything `[@@deriving quickcheck]` produces. A complete working
engine runs on this seam today:
https://github.com/matthiasgoergens/tapecheck. Measured there over six
properties and 100 seeds each, the stock greedy `Shrinker.t` loop was
fully minimal on 0/600 failing cases (scalar shrinkers are `atomic`,
and bind-shaped generators have no derivable shrinker), while the tape
engine over this seam reached the exact global minimum on 600/600.
The repo's README and design notes have the details, including two
findings about generator structure that the tape surfaced
(`int_inclusive`'s constant branches trap shortlex shrinking;
`list_generic` spends several draws per element).

Two implementation notes reviewers should check:

- Hook fallbacks are non-reentrant: `float`'s default samples via the
  unhooked `unit_float`/`bool` internals, so a hooked `float` draw is
  observed exactly once. (Getting this wrong double-records and
  desyncs replay; the tapecheck round-trip test catches it.)
- The patch is based on the released v0.17 line because the public
  toolchain cannot build the mirror's master (it needs capsule0.prim,
  which is ahead of the published 5.2.0+ox overlay). Porting to master
  raises a real design question, below.

Open design question for maintainers (the mode system raised it): with
hooks carried inside `t`, a hooked state is nonportable data, which
conflicts with `copy_into_capsule`/`split_into_capsule` on master and
with treating draw-closures as portable in general. Options seem to
be: require hook fields to be `portable` (data-race freedom composes,
but recording observers inherently capture mutable state, so they
would need capsule discipline); give the field a nonportable modality
and keep the capsule constructors hook-free (what this patch does
semantically: capsule copies drop hooks); or hold the hooks outside
`t` in a wrapper type (pushes a type change onto every caller, which
defeats the zero-changes goal). We would value your guidance; the
tapecheck repo's blog drafts document how far we got.

## Open questions for Matthias

- Base: submit against v0.17.0 as drafted (honest, verifiable), or
  attempt a master port with the capsule functions dropping hooks and
  note it cannot be locally verified?
- Also prepare the companion base_quickcheck PR (a Test.run variant on
  the tape engine)? Suggest holding until the seam lands or gets
  feedback.
- CLA: Jane Street requires a signed contributor agreement for PRs;
  check before submitting.
- Timing: submit before or after publishing blog post 1? The PR body
  links the repo either way; the post makes a warmer landing.

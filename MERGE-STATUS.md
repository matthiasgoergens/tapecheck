# Integration status

Updated 2026-08-10 on `wave1/finish`.

## Wave 1 integrated locally

The unchanged-generator path is complete in this integration branch. It
contains budgets and resumable shrinking, database replay, determinism checks,
statistics and health checks, generated-function streams, parallel execution,
stateful and bisimulation testing, targeting and multi-failure kernels, plus
the domain identity/order correction and their property laws.

The remaining Wave 1 topic branches were consolidated here: the dead-pass
cleanup, challenge refresh and two-sided guard, documentation/test fixes,
`non_uniform` proposal evidence, relation verification, structural identity
laws, `sort_siblings` evidence, and the current Hypothesis-gap inventory.
`Tape_test` now also exposes `with_sample` and `with_sample_exn`, rejects a
half-configured database, reports explicit-example failures, and database
writes use unique same-directory temporary files.

This is local integration status, not publication status: nothing in this
branch has been pushed by the Wave 1 close-out. The full forced suite and the
top-level engine-name guard are acceptance checks. The latter protects the
specific class of merge loss it was written for; it is not a complete OCaml
API-compatibility proof.

## Deliberately outside Wave 1

- `docs/wave-2-design`: generator-aware spans and the later pass work.
- `bug/nested-list-length`: the reproducer for anti-monotone list budgeting.
- `wave2/monotone-list-sizes`: the list-generator rewrite and its unresolved
  size-bound/distribution trade-off.
- `hypothesis-baseline`: the separate Python comparison harness.

## External publication dependency

The repository remains a source-workspace proof of concept rather than an opam
package. A linked consumer needs the patched `splittable_random` underneath a
recompiled `base_quickcheck`; upstream `janestreet/splittable_random#2` is still
open. Vendoring proves the unchanged-generator integration, but publishing the
vendored libraries under the same findlib names would conflict with the normal
packages rather than constitute a safe drop-in release.

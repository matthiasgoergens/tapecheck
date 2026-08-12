# Wave 2 checkpoint: production structural generators

Implemented 2026-08-12 on `wave2/span-deletion`. The previously measured list,
leaf-budget, and discarded-region mechanisms now exist in the vendored
`Base_quickcheck.Generator` API, while the legacy defaults remain unchanged.

## New opt-in API

`Generator.list_structural` preserves `Generator.list`'s marginal log-uniform
length distribution, but represents each optional element as a conditional
continuation Boolean followed by the element in one deletable span. Elements
receive the ambient size independently of list length. Optional `min_length`
and `max_length` bounds retain their usual meaning.

`Generator.recursive_with_max_leaves` follows Hypothesis's recursive strategy:

- a base draw consumes one leaf;
- a bounded tower mixes the base with successively recursive strategies;
- an attempt which requests more than `max_leaves` is discarded and retried
  from the advanced choice stream;
- Tapecheck records the failed attempt as a discarded span, which the
  `remove_discarded` pass can erase before ordinary shrinking.

The default leaf cap is 100, matching Hypothesis. The new Base Quickcheck API
also defaults to at most 1,000 consecutive over-cap attempts. This is an
intentional local safety difference: Hypothesis surrounds its unbounded
strategy retry with engine health checks, while Base Quickcheck has no
per-example deadline. Exhausting this deliberately generous bound raises a
generator exception, including during a Tapecheck replay; a small value is a
diagnostic setting rather than a normal operating mode.
The bounded strategy tower is rebuilt for each generated value so that leaf
counters are never shared between concurrent draws; recursive layer builders
should therefore be pure and inexpensive. The finite tower bounds recursive
layer depth logarithmically in the leaf cap, though it cannot bound arbitrary
work hidden inside the base generator.

OCaml has no analogue of Python's `BaseException` outside an ordinary catch-all
handler. The implementation therefore sets an independent breach flag before
raising its private limit exception. Even if user code catches that exception
with `try ... with _`, returning from the recursive layer causes the complete
attempt to be rejected. The exception constructor is fresh for every generated
value, so nested leaf-budget generators cannot intercept one another's limit
signals. Two 1,000-seed regressions exercise the catch-all and nesting cases.

## Why these are not the defaults yet

Replacing `Generator.list` alone would make existing `Generator.fixed_point`
programmes unsafe. Its documented termination story currently depends on list
elements receiving strictly smaller portions of the ambient size. Structural
lists deliberately remove that coupling; callers must instead put recursive
complexity under `recursive_with_max_leaves`.

The opt-in checkpoint lets real consumers migrate and supplies a candidate
upstream API without silently changing every existing generator. The current
implementation depends on the companion `splittable_random` span/interception
patch, so the two seams must be proposed together (or the span calls made
optional) rather than sending this Base Quickcheck patch alone. Replacing the defaults
requires a migration plan for `fixed_point`, `recursive_union`, and code which
relies on the current `sizes` contract. The old APIs and distributions remain
byte-for-byte unchanged in this checkpoint.

## Validation

`test_bq/test_structural_generators.ml` checks:

- 50,000 raw samples from stock and structural lists at size 10; the
  predeclared two-sample chi-square guard is below 40 (observed 10.74 across
  eleven bins);
- exact `min_length`/`max_length` behaviour and ambient element sizes;
- the leaf bound across 5,000 recursive draws;
- protection against swallowed and cross-nested limit exceptions, plus a
  working attempt cap;
- fifty structural-list shrink runs all reaching the exact `[100]` sum
  counterexample;
- twenty capped recursive-tree shrink runs all reaching the exact twenty-node
  boundary.

The full OCaml 5.3 suite, OxCaml build, consumer snapshot check, and pinned
vendor-provenance reconstruction must remain green before this checkpoint is
committed.

## Next decision

Use the opt-in API in at least one real recursive consumer and repeat the
quality/cost suite. If that remains healthy, propose these functions and their
companion span seam upstream as additions first. A later breaking release can consider making structural
lists the default alongside a replacement or deprecation path for
size-dependent `fixed_point` recursion. First-class string and bytes choices
remain the next independent shrinking capability.

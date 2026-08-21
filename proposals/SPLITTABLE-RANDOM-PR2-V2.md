# Minimal v2 delta for `splittable_random#2`

`splittable_random-pr2-v2.patch` is the retained review delta that was applied
to the public PR on 2026-08-21:

- PR: `janestreet/splittable_random#2`
- original head: `3726e515f53cbbfd3e801d92aebfa8acd31c5adc`
- updated head: `e50930a084696d85984fbdb6a4526fb59f489377`
- base: `e20072cb64db9ddb0b50a5471b51014cae5981bc`
- patch SHA-256: `e08b16717057470ed7bbc7a6d576a090828e83f391baa3564a166c9cf9365e05`
- checked: 2026-08-20 and rerun before publication on 2026-08-21

It deliberately does not add Tapecheck's Wave 2 weighted choices or spans, and
does not add the accelerated-backend `run_*` functions. It changes only the
part of the submitted Wave 1 contract which current end-to-end function tests
show to be necessary:

- `Intercept.t` becomes abstract;
- `Intercept.create` provides optional, delegating primitive callbacks;
- `on_split` returns the observer to attach to the new child;
- `on_perturb` receives the salt and may replace the current observer;
- ordinary `split` and `perturb` install those returned observers;
- capsule copies and splits remain hook-free; and
- `with_intercept` is documented correctly as returning a snapshot copy.

The delta adds inline controls for delegating defaults, observed child states,
the default hook-free child, salt delivery, and observer replacement.

## Verification boundary

The patch is generated directly from a detached checkout of the exact PR head,
so it applies there without context guessing. Its source and inline tests pass
under the installed public `5.2.0+ox` switch after the same compatibility-only
substitutions already documented in the PR thread:

- dune library `capsule0.prim` → `capsule`; and
- module `Capsule_prim` → `Capsule_expert`.

Those substitutions bridge the public overlay's older capsule name and are not
part of the retained patch. After testing, they were reversed before the delta
was generated. The exact successful command was:

```sh
opam exec --switch=5.2.0+ox -- dune runtest src --force
```

Building the untouched PR source under the product's OCaml 5.3 switch is not a
valid alternative verification: that switch lacks both `capsule0.prim` and the
PR test suite's `expect_test_helpers_core` dependency.

The updated PR branch is the authoritative review surface. This retained delta
records exactly how the original submitted contract became commit `e50930a`.

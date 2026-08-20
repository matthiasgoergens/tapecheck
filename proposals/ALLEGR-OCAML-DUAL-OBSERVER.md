# AllegrOCaml dual-observer proposal

`allegr_ocaml-dual-observer.patch` is a local, unposted patch against the
published AllegrOCaml source:

- repository: `alpha-convert/waffle-house`;
- revision: `69d843f2a91a51321ea82418cf4766e115b684e3`;
- relevant directory: `staged-ocaml`;
- patch SHA-256:
  `a7a8291ea4a969e25956fab22c4a9bb9ec4e6e118cfaf71c036c0613b31a6dd0`;
- v0.16 observer-backport SHA-256:
  `4ea9b677f7f2e73d0d0a740e9a0f6b2a6dd4aff9b6b5e0c0d723e7eaa8fb6854`;
- checked: 2026-08-20.

The patch generates two complete functions for one generator description:

- a direct function from `C_sr_dropin_random`; and
- an observable function from `Sr_random`.

It selects between them with `Splittable_random.Intercept.is_active` at the
`Base_quickcheck.Generator.create` boundary. The inactive path therefore pays
one branch per generated value, rather than one OCaml dispatch per primitive
draw. Existing single-backend `to_bq` and `jit` calls keep their source API and
are refactored through the same compiled-function representation.

The generator description must still be instantiated once for each backend.
Existing generator functors such as the artifact's `TestCase.F` make that
straightforward, but the patch does not make arbitrary already-instantiated
generators backend-polymorphic. `C_random`, which copies the random state into
an independent representation, remains outside the supported pair.

## Smoke test

The patch includes a small test which:

1. uses distinct constant bodies to prove that inactive and active states
   select the direct and observed functions respectively; and
2. checks that the direct-C and ordinary-SR Boolean bodies produce identical
   values for 100 paired seeds, while asserting one real observer callback per
   active generated value.

I built the library and ran that test under a fresh BER MetaOCaml 4.14.1 switch:

```sh
opam exec --switch=/tmp/tapecheck-ber -- dune build lib
opam exec --switch=/tmp/tapecheck-ber -- dune runtest seam-smoke --force
opam exec --switch=/tmp/tapecheck-ber -- dune runtest dual-smoke --force
```

Both commands passed. The host's GCC 16.2.1 inherits GCC 15's C23 default,
under which the old BER compiler does not build; the switch was therefore
created with `CC="gcc -std=gnu17"`, following the [GCC 15 porting guide's compatibility
route](https://gcc.gnu.org/gcc-15/porting_to.html).

The frozen dependency solver selects `splittable_random` v0.16.0, which has no
interception API. `splittable_random-v016-observer.patch` backports the relevant
observer contract: delegating Boolean, integer, float, and unit-float hooks;
active-state detection; snapshot attachment; and observer propagation choices
for split and perturb. Its isolated smoke target checks one callback per
primitive and the split/perturb replacement behaviour. The AllegrOCaml smoke
test was then rerun against that installed backport. Tapecheck's product tests
cover recording and replay separately.

The artifact's broad `dune runtest` target remains independently broken in
this reconstruction because an undeclared `util` test library is absent. The
new `dual-smoke` target is isolated from those historical test dependencies.

## Verification boundary

This establishes that the dual-code architecture is valid MetaOCaml, links,
runs, selects both bodies, invokes the real observer callback, and preserves
paired Boolean output in the pinned source/toolchain. It does not establish
performance for AllegrOCaml workloads, recording-mode throughput, or complete
bug-finding throughput.

Both retained zero-context patches apply with `git apply --unidiff-zero` to
fresh source trees. Nothing has been posted to either upstream repository.

# Testing `core`-dependent code with tapecheck: the opam-pin recipe

The vendoring trick in this repo (see `vendor/`) makes the tape engine work for
code that only depends on `base`: the workspace owns the `splittable_random`
and `base_quickcheck` library names, so every generator draw is intercepted.
That recipe breaks down for code that links `core` (or `core_kernel`, or
anything else whose compiled artifacts import the `Splittable_random` /
`Base_quickcheck` interfaces): opam-installed `core` was compiled against the
*unpatched* libraries, so mixing it with the workspace shims fails at link
time with "inconsistent assumptions over interface Splittable_random".

The fix is to move the shims one level up: **install them as opam pins** in a
dedicated switch, so opam rebuilds every reverse dependency (`core`,
`core_kernel`, ...) from source against the shims. No workspace vendoring, no
digest conflicts.

A complete, working consumer workspace lives in
[`bonsai-tapecheck-hunt/`](../bonsai-tapecheck-hunt) at the root of this repo.
It property-tests two libraries copied out of
[janestreet/bonsai](https://github.com/janestreet/bonsai)
(`balance_list_tree`, `trampoline`) — both `core`-based — through the tape
engine. It is excluded from the root build (see the root `dune`); treat it as
its own project.

Because this workspace is package-shaped, it contains copies of the engine
and tape seam rather than referencing the parent libraries. The root
`runtest` alias runs `scripts/check_consumer_snapshot.sh` to prevent a green
consumer run from silently validating an older snapshot.

## Layout

- `bonsai-tapecheck-hunt/pkgs/splittable_random/` — the shim as an
  opam-installable package: one `(wrapped false)` library exposing the modules
  `Splittable_random` (shim, including `For_tape`), `Sr_real` (upstream +
  intercept seam, from `vendor/sr_real/`), and `Tape` (from `tape/`). Version
  pinned as `v0.17.0` to satisfy revdep constraints.
- `bonsai-tapecheck-hunt/pkgs/base_quickcheck/` — the vendored
  `base_quickcheck` v0.17.1 sources as an opam-installable package, with the
  ppx pieces exposed under the exact upstream sublibrary names
  (`base_quickcheck.ppx_quickcheck{,.expander,.runtime}`). The names matter:
  e.g. `core_kernel.nonempty_list` depends on
  `base_quickcheck.ppx_quickcheck.runtime`.
- `bonsai-tapecheck-hunt/engine/` — a copy of this repo's `engine/` (the
  `Tape_test` runner), with `tape` dropped from its library list (the `Tape`
  module now comes from the pinned `splittable_random` package).
- `bonsai-tapecheck-hunt/libs/` — the two libraries under test, copied
  unmodified from bonsai (MIT). Point these at whatever you want to hunt in.
- `bonsai-tapecheck-hunt/hunt/` — the property tests, using
  `[@@deriving quickcheck]` unchanged and `Tape_test` as a drop-in for
  `Base_quickcheck.Test`.

## Commands that worked

```sh
opam switch create tapecheck-hunt ocaml-base-compiler.5.3.0 \
  --repos default=https://opam.ocaml.org --yes
opam pin add splittable_random bonsai-tapecheck-hunt/pkgs/splittable_random \
  --switch=tapecheck-hunt --yes --no-action
opam pin add base_quickcheck  bonsai-tapecheck-hunt/pkgs/base_quickcheck \
  --switch=tapecheck-hunt --yes --no-action
opam install --switch=tapecheck-hunt --yes \
  core core_kernel ppx_sexp_conv ppx_compare ppx_let ppx_fields_conv \
  ppx_sexp_message ppx_sexp_value ppx_base ppxlib_jane
cd bonsai-tapecheck-hunt
opam exec --switch=tapecheck-hunt -- dune build --root .
opam exec --switch=tapecheck-hunt -- dune runtest --root . --force
```

Everything depending on the shimmed interfaces (`core` v0.17.2, `core_kernel`
v0.17.0, the ppx stack) is compiled from source against the pins. Note the
v0.17 Jane Street stack builds fine on stock OCaml 5.3 — the `effect`-keyword
problem (janestreet/bonsai#47) does not affect it.

### Fresh verification, 2026-08-20

The recipe was repeated from an empty switch named
`tapecheck-hunt-20260820-15324a9`, without modifying the earlier
`tapecheck-hunt` switch. Both replacement packages were pinned to this
checkout, then `core` and `core_kernel` were installed. The explicit
`core_kernel` install is required because the copied Bonsai libraries depend on
the separate `core_kernel.nonempty_list` library.

After adding the explicit core interfaces, the following commands rebuilt the
consumer and force-ran seven passing properties plus one deliberately failing
positive control successfully:

```sh
opam exec --switch=tapecheck-hunt-20260820-15324a9 -- \
  dune build --root .
opam exec --switch=tapecheck-hunt-20260820-15324a9 -- \
  dune runtest --root . --force
```

This is a consumer verification, not a claim that the root `tape` package is
installable. The switch contains deliberate opam-level replacements for
`splittable_random` and `base_quickcheck`, and its reverse dependencies were
rebuilt against them.

## Evidence

The explicit `--root .` is essential: without it, dune discovers the parent
tapecheck workspace, where this nested project is marked `data_only`, and a
nominally successful test command runs no consumer tests. `--force` makes the
three test executables run again rather than replaying dune's cache.

The real nested `dune runtest --root . --force` prints one tape-engine summary
line per property run:

```
tapecheck: 10000 cases (10000 valid, 0 discarded, 0 failing)
```

Seven property runs (3 for `balance_list_tree`, 4 for `trampoline`) are green.
The eighth property is a positive control over an atomic integer shrinker: it
must discover `value >= 123457` and report exactly `123457`. The executable
handles that expected failure and prints:

```
consumer positive control: found and shrank exactly to 123457
```

This distinguishes “the replacement libraries link and passing tests run”
from “the installed tape engine actually intercepts choices and shrinks a
failure to its boundary”.

## Why this matters for tapecheck itself

The root workspace now exposes a checked three-pin preview: replacement
`splittable_random` and `base_quickcheck` packages plus `tapecheck`. Run
`scripts/test_opam_install.sh` against a disposable OCaml 5.3 switch for the
small installed-package control. A normal single-package release remains
blocked on
[janestreet/splittable_random#2](https://github.com/janestreet/splittable_random/pull/2)
(the intercept-seam discussion). The submitted v1 diff does not propagate
observers into split children and therefore cannot replace the current seam
unchanged. The `pkgs/` packaging here is the larger Core rebuild: the shim *is* the
`splittable_random` package (with `Tape` as an extra module), so downstream
opam builds get tape recording today under an explicit replacement pin.
Current integration shape and remaining questions:

- `pkgs/` is a generated snapshot of the canonical `engine/`, `tape/`, and
  `vendor/` sources. Refresh it with
  `scripts/sync_consumer_snapshot.sh --update`; the root `runtest` alias and CI
  compare every copied `.ml`/`.mli`, including the ppx sources.
- The copied engine remains deliberate: this workspace predates the root
  package and proves source parity against the exact stack used to rebuild
  `core`, while `install-smoke/` proves the installed-library boundary.
- Version alignment: the shims are v0.17-based while the Jane Street bleeding
  repo is on v0.18 previews. Porting the seam to v0.18
  (janestreet/splittable_random master) is a separate, small job — the seam
  diff is ~100 lines in `sr_real.ml{,i}`.

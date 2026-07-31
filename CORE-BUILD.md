# Can core's own test suite be built outside Jane Street?

Attempted, time-boxed, and the answer is "not without the OxCaml
compiler". Recording the chain so nobody repeats it.

## What was tried

`core/test` needs `capsule`, `ppx_bin_and_sexp_digest`,
`unboxed_test_harness` and `expectable`, none of which are in
opam-repository. Three of the four *are* on GitHub under `janestreet/`,
so opam pinning from git looked like the fix:

```
opam pin add capsule                https://github.com/janestreet/capsule.git
opam pin add ppx_bin_and_sexp_digest https://github.com/janestreet/ppx_bin_and_sexp_digest.git
opam pin add expectable             https://github.com/janestreet/expectable.git
```

All three pin cleanly. Installing does not:

```
capsule -> capsule0            (pinned it too; also on GitHub)
capsule -> capsule0 -> basement (another unpublished package)
```

## Why the chase is the wrong move

The GitHub descriptions give it away: *"The capsule api for the **OxCaml**
mode ecosystem"*, *"The expert capsule api for the OxCaml mode
ecosystem"*.

These target **OxCaml**, Jane Street's OCaml fork with mode annotations,
not stock OCaml 5.3.0. The evidence is in the source rather than the
metadata — core is thick with mode syntax that stock OCaml cannot parse:

```
core/src/binable_intf.ml   58 mode annotations
core/src/make_stable.ml    56
core/src/comparable.ml     46
```

and the vendored `base_quickcheck/generator.ml` in this very repo carries
`[@mode p]`, `[@@@mode.default p]` throughout.

So this is not a packaging gap that pinning fixes. Following the
dependency chain to its end would still leave a tree that stock OCaml
cannot compile.

## What would actually work, if it is worth it

There is a `5.2.0+ox` switch on this machine already, which is OxCaml.
Building core's tests there is plausible but is its own project: a fresh
switch, the whole janestreet dependency tree pinned from git, and no
guarantee `unboxed_test_harness` exists publicly at all (it does not
appear on GitHub, and is referenced only from `core/test/dune`).

## Consequence for the work that wanted this

The profiling in `SPANS-THE-ROOT-CAUSE.md` used *reconstructions* of
shapes carrying `[@@deriving quickcheck]` in core — `Blang.t`, records,
maps, strings — rather than core's own derived generators. That remains
the honest position and the write-up says so. The reconstructions are
faithful in shape; what they cannot capture is whatever the deriver
emits that a hand-written equivalent does not.

This also strengthens, slightly, the point made in `janestreet/core#182`:
a test suite that needs an unreleased compiler fork plus unpublished
packages is one no outside contributor can run, which is a plausible
part of why a `n mod 0` typo survived six years.

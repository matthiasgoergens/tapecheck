# Installed-package smoke test

This is a separate Dune project. It must compile against packages installed in
an opam switch, not against libraries from the parent source workspace.

Run it through the repository-level installation check:

```sh
./scripts/test_opam_install.sh DISPOSABLE_OCAML_5_3_SWITCH
```

Success prints
`installed Tape_test facade passed; Tape_engine shrank to 50`. The fixture
compiles an ordinary `[@@deriving quickcheck]` declaration, runs the intended
`Tape_test` facade through its `Base_quickcheck.Test.S`-compatible module type,
and checks the lower-level engine's exact shrink result. A missing PPX/runtime
installation or facade module therefore cannot be mistaken for a working
package.

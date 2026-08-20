# Installed-package smoke test

This is a separate Dune project. It must compile against packages installed in
an opam switch, not against libraries from the parent source workspace.

Run it through the repository-level installation check:

```sh
./scripts/test_opam_install.sh DISPOSABLE_OCAML_5_3_SWITCH
```

Success prints `installed Tapecheck shrank to 50`. The fixture also compiles an
ordinary `[@@deriving quickcheck]` declaration, so a missing PPX/runtime
installation cannot be mistaken for a working package.

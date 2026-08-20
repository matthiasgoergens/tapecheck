#!/bin/sh
set -eu

if test "$#" -ne 1; then
  echo "usage: $0 DISPOSABLE_SWITCH" >&2
  echo "the switch is modified by installing three local pins" >&2
  exit 2
fi

switch=$1
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
product_dir=$(dirname -- "$script_dir")

compiler=$(opam exec --switch="$switch" -- ocamlc -version)
if test "$compiler" != "5.3.0"; then
  echo "opam-install: expected OCaml 5.3.0 in $switch, found $compiler" >&2
  exit 1
fi

for package in splittable_random base_quickcheck tapecheck; do
  opam pin add --switch="$switch" --kind=path "$package" "$product_dir" --yes
done

(
  cd "$product_dir/install-smoke"
  opam exec --switch="$switch" -- dune exec --root . ./main.exe
)

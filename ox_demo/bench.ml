(* Same-source benchmark for stock OCaml vs OxCaml (Flambda2): time
   the full find-and-shrink cycle on the bind-heavy property from the
   shrink table. No ppx, so it builds under both switches. *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

let trials = 200

let gen =
  G.bind (G.int_uniform_inclusive 1 64) ~f:(fun len ->
    G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)

let test l = List.sum (module Int) l ~f:Fn.id < 100

let () =
  let minimal_count = ref 0 in
  let attempts_total = ref 0 in
  let t0 = Stdlib.Sys.time () in
  for trial = 0 to trials - 1 do
    match
      Tape_engine.run gen ~test ~seed:(trial * 1_000_003) ~count:200
        ~size:10 ~budget:5000
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; attempts; _ } ->
      attempts_total := !attempts_total + attempts;
      if List.equal Int.equal minimal [ 100 ] then Int.incr minimal_count
  done;
  let cpu = Stdlib.Sys.time () -. t0 in
  printf "compiler: %s\n" Stdlib.Sys.ocaml_version;
  printf "trials: %d, fully minimal: %d, total shrink attempts: %d\n" trials
    !minimal_count !attempts_total;
  printf "cpu: %.3fs  (%.1f us per attempt)\n" cpu
    (cpu *. 1e6 /. Float.of_int !attempts_total)

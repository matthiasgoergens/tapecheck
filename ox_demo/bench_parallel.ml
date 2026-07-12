(* Parallel shrinking benchmark: an expensive property (a busy-work
   checksum emulating a real test body) over a bind-heavy generator,
   shrunk with 1 domain vs several. *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

let trials = 20
let now () = Unix.gettimeofday ()

(* Fixed ~100us of work per test call, independent of input size,
   emulating a real system under test. *)
let busy_work l =
  let h = ref (List.length l) in
  for i = 1 to 200_000 do
    h := (!h * 31) + i
  done;
  !h

let gen =
  G.bind (G.int_uniform_inclusive 1 256) ~f:(fun len ->
    G.list_with_length (G.int_uniform_inclusive 0 10_000) ~length:len)

(* Rare failures: most cases pass, so the generate-and-test phase
   dominates, which is the realistic regime for parallelism. *)
let test l =
  let (_ : int) = busy_work l in
  List.sum (module Int) l ~f:Fn.id < 1_200_000

let bench ~domains =
  let found = ref 0 in
  let attempts_total = ref 0 in
  let w0 = now () in
  let t0 = Stdlib.Sys.time () in
  for trial = 0 to trials - 1 do
    match
      Tape_engine.run gen ~test ~seed:(trial * 1_000_003) ~count:50 ~size:10
        ~budget:3000 ~domains
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { attempts; _ } ->
      Int.incr found;
      attempts_total := !attempts_total + attempts
  done;
  let cpu = Stdlib.Sys.time () -. t0 in
  let wall = now () -. w0 in
  printf
    "domains=%2d  found %2d/%d  attempts %6d  wall %6.2fs  cpu %6.2fs\n"
    domains !found trials !attempts_total wall cpu

let () =
  printf "compiler: %s\n" Stdlib.Sys.ocaml_version;
  bench ~domains:1;
  bench ~domains:4;
  bench ~domains:8;
  bench ~domains:(min 16 (Stdlib.Domain.recommended_domain_count ()))

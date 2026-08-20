open! Base
open Base_quickcheck.Export

type pair = int * int [@@deriving quickcheck]

let () =
  (* Compiling this reference proves that the replacement package installed
     the ordinary Base_quickcheck PPX and runtime surface. *)
  ignore quickcheck_generator_pair;
  let generator = Base_quickcheck.Generator.int_uniform_inclusive 0 1_000 in
  match
    Tape_engine.run generator ~seed:20260820 ~count:100 ~size:10
      ~test:(fun value -> value < 50)
  with
  | Passed _ -> failwith "expected to find a counterexample"
  | Failed { minimal; _ } ->
    if minimal <> 50 then failwith (Printf.sprintf "expected 50, got %d" minimal);
    Stdlib.Printf.printf "installed Tapecheck shrank to %d\n" minimal

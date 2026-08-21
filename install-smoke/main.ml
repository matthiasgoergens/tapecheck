open! Base
open Base_quickcheck.Export

type pair = int * int [@@deriving quickcheck]

module Pair_testable : Tape_test.S with type t = pair = struct
  type t = pair

  let sexp_of_t (left, right) =
    Sexp.List [ Int.sexp_of_t left; Int.sexp_of_t right ]

  let quickcheck_generator = quickcheck_generator_pair
  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

let () =
  (* Compiling this reference proves that the replacement package installed
     the ordinary Base_quickcheck PPX and runtime surface. *)
  ignore quickcheck_generator_pair;
  (match
     Tape_test.run
       ~f:(fun (_ : pair) -> Ok ())
       ~config:
         { Tape_test.default_config with
           seed = Deterministic "installed-facade"
         ; test_count = 3
         ; sizes = Sequence.of_list [ 0; 1; 10 ]
         }
       (module Pair_testable)
   with
   | Ok () -> ()
   | Error error -> failwith (Error.to_string_hum error));
  let generator = Base_quickcheck.Generator.int_uniform_inclusive 0 1_000 in
  match
    Tape_engine.run generator ~seed:20260820 ~count:100 ~size:10
      ~test:(fun value -> value < 50)
  with
  | Passed _ -> failwith "expected to find a counterexample"
  | Failed { minimal; _ } ->
    if minimal <> 50 then failwith (Printf.sprintf "expected 50, got %d" minimal);
    Stdlib.Printf.printf
      "installed Tape_test facade passed; Tape_engine shrank to %d\n"
      minimal

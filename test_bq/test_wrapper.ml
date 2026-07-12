(* The drop-in wrapper: same signatures as Base_quickcheck.Test, tape
   shrinking underneath. *)

open! Base
open Base_quickcheck.Export

type pair = int * int [@@deriving quickcheck, sexp_of, compare]

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let () =
  (* result: typed failure carries the tape-minimal input. *)
  (match
     Tape_test.result
       ~f:(fun (a, b) -> if a + b >= 100 then Error "too big" else Ok ())
       (module struct
         type t = pair [@@deriving sexp_of]

         let quickcheck_generator =
           Base_quickcheck.Generator.both
             (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)
             (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)

         let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
       end)
   with
  | Ok () -> failwith "expected a failure: pair"
  | Error ((a, b), msg) ->
    Stdlib.Printf.printf "wrapper/result: minimal=(%d, %d) error=%s\n" a b msg;
    check "wrapper shrinks to (0, 100)" (a = 0 && b = 100));

  (* run: Or_error, drop-in shape. *)
  (match
     Tape_test.run
       ~f:(fun (a, b) ->
         if a + b >= 100 then Or_error.error_string "too big" else Ok ())
       (module struct
         type t = pair [@@deriving sexp_of]

         let quickcheck_generator =
           Base_quickcheck.Generator.both
             (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)
             (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)

         let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
       end)
   with
  | Ok () -> failwith "expected a failure: run"
  | Error e ->
    let s = Sexp.to_string (Error.sexp_of_t e) in
    check "run reports the minimal input" (String.is_substring s ~substring:"(0 100)"));

  (* A passing property passes. *)
  (match
     Tape_test.run
       ~f:(fun (a, b) -> if a + b >= 0 then Ok () else Or_error.error_string "impossible")
       (module struct
         type t = pair [@@deriving sexp_of]

         let quickcheck_generator =
           Base_quickcheck.Generator.both
             (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)
             (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)

         let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
       end)
   with
  | Ok () -> ()
  | Error _ -> failwith "expected pass");

  Stdlib.print_endline "all wrapper tests passed"

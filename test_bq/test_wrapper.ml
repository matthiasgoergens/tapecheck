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

  (* Regression persistence: a shrunk failure saves a tape; a rerun
     replays the exact value before generating anything; a corrupt
     line fails loudly. *)
  let reg_file = Stdlib.Filename.temp_file "tape_test_regressions" ".txt" in
  Stdlib.Sys.remove reg_file;
  let gen_module =
    (module struct
      type t = pair [@@deriving sexp_of]

      let quickcheck_generator =
        Base_quickcheck.Generator.both
          (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)
          (Base_quickcheck.Generator.int_uniform_inclusive 0 1000)

      let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
    end : Base_quickcheck.Test.S
      with type t = pair)
  in
  let f (a, b) = if a + b >= 100 then Error "too big" else Ok () in
  (match Tape_test.result ~f ~regressions:reg_file gen_module with
  | Error ((0, 100), _) -> ()
  | other ->
    ignore other;
    failwith "expected (0, 100) with regression file");
  check "regression file written" (Stdlib.Sys.file_exists reg_file);
  (* Rerun with a test_count of zero: only the replayed tape can fail. *)
  let no_random_config =
    { Tape_test.default_config with test_count = 0; sizes = Sequence.empty }
  in
  (match
     Tape_test.result ~f ~config:no_random_config ~regressions:reg_file
       gen_module
   with
  | Error ((0, 100), _) -> ()
  | Ok () -> failwith "regression replay missed the persisted failure"
  | Error (other, _) ->
    failwith
      (Printf.sprintf "regression replayed wrong value: (%d, %d)"
         (fst other) (snd other)));
  (* An entry that replays to a PASSING value is loud too: a
     regression that stops guarding must not silently pass. *)
  (match
     Or_error.try_with (fun () ->
       Tape_test.result
         ~f:(fun (_ : pair) -> Ok ())
         ~config:no_random_config ~regressions:reg_file gen_module)
   with
  | Error _ -> ()
  | Ok _ -> failwith "stale passing regression entry did not fail loudly");

  (* Corrupt the file: loud error, not a silent pass. *)
  Stdlib.Out_channel.with_open_gen [ Open_append; Open_text ] 0o644 reg_file
    (fun oc -> Stdlib.Printf.fprintf oc "zz-not-hex\n");
  (match
     Or_error.try_with (fun () ->
       Tape_test.result ~f ~config:no_random_config ~regressions:reg_file
         gen_module)
   with
  | Error _ -> ()
  | Ok _ -> failwith "corrupt regression line did not fail loudly");
  Stdlib.Sys.remove reg_file;

  Stdlib.print_endline "all wrapper tests passed"

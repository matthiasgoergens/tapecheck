(* The drop-in wrapper: same signatures as Base_quickcheck.Test, tape
   shrinking underneath. *)

open! Base
open Base_quickcheck.Export

type pair = int * int [@@deriving quickcheck, sexp_of, compare]

(* Compile-time coverage for the module type in Base_quickcheck.Test's public
   surface, not just its five value-level entry points. *)
module Pair_testable : Tape_test.S with type t = pair = struct
  type t = pair [@@deriving sexp_of]

  let quickcheck_generator = quickcheck_generator_pair
  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let failure_with_distinctive_backtrace () =
  failwith "distinctive backtrace failure"

let () =
  (* [with_sample] and [with_sample_exn] complete the callable, source-level
     surface. They deliberately retain Base's stock sampler rather than
     previewing Tape_test.run. Examples precede the configured number of
     generated values, just as they do upstream. *)
  let sample_config =
    { Tape_test.default_config with
      seed = Deterministic "with-sample"
    ; test_count = 3
    ; sizes = Sequence.of_list [ 0; 1; 2 ]
    }
  in
  let samples = ref [] in
  (match
     Tape_test.with_sample
       ~f:(fun xs ->
         samples := Sequence.to_list xs;
         Ok ())
       ~config:sample_config ~examples:[ 41; 42 ]
       (Base_quickcheck.Generator.int_uniform_inclusive 0 10)
   with
   | Ok () -> ()
   | Error _ -> failwith "with_sample callback unexpectedly failed");
  check "with_sample preserves examples and test_count"
    (List.length !samples = 5
     && List.equal Int.equal (List.take !samples 2) [ 41; 42 ]);
  let base_samples = ref [] in
  Base_quickcheck.Test.with_sample_exn
    ~f:(fun xs -> base_samples := Sequence.to_list xs)
    ~config:sample_config ~examples:[ 41; 42 ]
    (Base_quickcheck.Generator.int_uniform_inclusive 0 10);
  check "with_sample preserves base_quickcheck sampling semantics"
    (List.equal Int.equal !samples !base_samples);
  let with_sample_exn_called = ref false in
  Tape_test.with_sample_exn
    ~f:(fun xs ->
      with_sample_exn_called := true;
      check "with_sample_exn gets configured sample"
        (Sequence.length xs = 3))
    ~config:sample_config
    (Base_quickcheck.Generator.int_uniform_inclusive 0 10);
  check "with_sample_exn invokes callback" !with_sample_exn_called;
  check "with_sample_exn propagates callback failure"
    (match
       Or_error.try_with (fun () ->
         Tape_test.with_sample_exn
           ~f:(fun _ -> failwith "sample callback")
           ~config:sample_config
           (Base_quickcheck.Generator.int_uniform_inclusive 0 10))
     with
     | Error _ -> true
     | Ok () -> false);

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

  (* Base_quickcheck.Test.run records the original exception backtrace whenever
     runtime backtrace recording is enabled.  The assume-aware compatibility
     wrapper must retain that diagnostic information too. *)
  Backtrace.Exn.with_recording true ~f:(fun () ->
    match
      Tape_test.run
        ~f:(fun () -> failure_with_distinctive_backtrace ())
        ~config:
          { Tape_test.default_config with
            seed = Deterministic "backtrace"
          ; test_count = 1
          ; sizes = Sequence.singleton 0
          }
        (module struct
          type t = unit [@@deriving sexp_of]

          let quickcheck_generator = Base_quickcheck.Generator.return ()
          let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
        end)
    with
    | Ok () -> failwith "expected a failure with a backtrace"
    | Error error ->
      let rendered = Error.to_string_hum error in
      check "run preserves the property exception backtrace"
        (String.is_substring rendered ~substring:"Raised at"));

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
  (* In the test's own directory, not /tmp. Same reasoning as
     test_db_wired.ml: dune gives each test a private directory, whereas
     a shared /tmp path is a predictable name that two concurrent
     checkouts can collide on. Filename.temp_file also LEAVES the file
     behind on the shared path, which this test then immediately removes
     only to recreate -- a window another run can land in. *)
  let reg_file = "test_wrapper_regressions.txt" in
  (try Stdlib.Sys.remove reg_file with Sys_error _ -> ());
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
  (* A half-configured database used to be silently disabled, making a typo
     look like persistence was active. *)
  let dummy_db = Tape_db.create ~dir:"unused-wrapper-db" () in
  let rejects_half_database thunk =
    match Or_error.try_with thunk with
    | Error _ -> true
    | Ok _ -> false
  in
  check "?db without ?db_key is rejected"
    (rejects_half_database (fun () ->
       Tape_test.result ~f:(fun (_ : pair) -> Ok ()) ~db:dummy_db
         ~report:`Silent gen_module));
  check "?db_key without ?db is rejected"
    (rejects_half_database (fun () ->
       Tape_test.result ~f:(fun (_ : pair) -> Ok ()) ~db_key:"property"
         ~report:`Silent gen_module));
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

  Stdlib.print_endline "test_wrapper: all passed"

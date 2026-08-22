(* Resumable shrinking (budgets-and-resume task, part 3): budget
   exhaustion must be reported as TRUNCATION, never silently mistaken
   for convergence; a resumed shrink must continue correctly and reach
   the same minimum an uninterrupted run would, given enough budget;
   and a round-tripped tape (the "ct1" serialization already used for
   regression files) must be faithful. All three are tested directly
   against [Tape_engine], plus one end-to-end pass through the
   [Tape_test] wrapper (the actual user-facing entry points) so the
   printed truncation message is exercised too, not just the
   structured [converged] field it is derived from. *)

open! Base
module G = Base_quickcheck.Generator

let check name cond = if not cond then failwith ("FAILED: " ^ name)

(* The hexadecimal regression-file transport is deliberately not part of the
   [Tape_test] API. These fixture helpers construct the documented wire format
   without reaching into the runner's private implementation module. *)
let hex_of_string s =
  String.concat_map s ~f:(fun c -> Printf.sprintf "%02x" (Char.to_int c))

let append_regression path ~image ~size ~comment =
  Stdlib.Out_channel.with_open_gen
    [ Open_append; Open_creat; Open_text ] 0o644 path
    (fun oc ->
      Stdlib.Printf.fprintf oc "%s @%d # %s\n"
        (hex_of_string (Tape.serialize_image image))
        size comment)

(* Capture what [f] prints to stdout, for checking the actual wording
   of the truncation message [Tape_test.result] prints -- not just the
   structured [converged] field it is derived from. Written under the
   current (build) directory rather than /tmp, and removed afterwards. *)
let capture_stdout (f : unit -> unit) : string =
  Stdlib.Out_channel.flush Stdlib.stdout;
  let path = "test_resume_stdout_capture.txt" in
  let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
  let saved_stdout = Unix.dup Unix.stdout in
  Unix.dup2 fd Unix.stdout;
  Unix.close fd;
  Exn.protect
    ~f:(fun () ->
      f ();
      Stdlib.Out_channel.flush Stdlib.stdout)
    ~finally:(fun () ->
      Unix.dup2 saved_stdout Unix.stdout;
      Unix.close saved_stdout);
  let contents = Stdlib.In_channel.with_open_text path Stdlib.In_channel.input_all in
  Stdlib.Sys.remove path;
  contents

(* Well-understood property, same shape as demo/shrink_table.ml's first
   row: a single scalar choice, one unique global minimum (123_457),
   reached deterministically by the engine's bisection pass. *)
let gen = G.int_uniform_inclusive 0 1_000_000
let test v = v < 123_457
let seed = 4242

let () =
  (* --- Truncation is reported as truncation, not convergence --- *)

  (* budget:0 -- the initial failing example is essentially never
     already-trivial for this property (target 0 needs a real draw of
     exactly 0, and the property's own minimum is 123_457, far from the
     shrink target), so shrinking never gets to run at all: this must
     be reported as NOT converged. *)
  let truncated =
    Tape_engine.run gen ~test ~seed ~count:200 ~size:10 ~budget:0
  in
  (match truncated with
  | Tape_engine.Passed _ -> failwith "expected a failure at budget 0"
  | Tape_engine.Failed { converged; minimal; attempts; _ } ->
    check "budget 0: reported as truncated, not converged" (not converged);
    check "budget 0: spent zero shrink attempts" (attempts = 0);
    check "budget 0: minimal is NOT the true minimum yet" (minimal <> 123_457));

  (* A generous budget on the very same seed converges to the true,
     unique minimum, and must say so. *)
  let converged_run =
    Tape_engine.run gen ~test ~seed ~count:200 ~size:10 ~budget:2000
  in
  (match converged_run with
  | Tape_engine.Passed _ -> failwith "expected a failure at budget 2000"
  | Tape_engine.Failed { converged; minimal; _ } ->
    check "budget 2000: reports converged" converged;
    check "budget 2000: reaches the true minimum 123457" (minimal = 123_457));

  (* A wall-clock deadline that has already passed truncates just like
     an exhausted attempt count does, and must say so too. *)
  let time_truncated =
    Tape_engine.run gen ~test ~seed ~count:200 ~size:10 ~budget:2000
      ~max_seconds:(Some 0.)
  in
  (match time_truncated with
  | Tape_engine.Passed _ -> failwith "expected a failure"
  | Tape_engine.Failed { converged; _ } ->
    check "max_seconds:0 truncates just like budget:0 does" (not converged));

  (* --- Resuming continues correctly, reaching the same minimum --- *)

  let truncated_image =
    match truncated with
    | Tape_engine.Failed { image; _ } -> image
    | Tape_engine.Passed _ -> assert false
  in
  let resumed =
    Tape_engine.resume gen ~test ~size:10 ~budget:2000 truncated_image
  in
  (match resumed with
  | Tape_engine.Passed _ ->
    failwith "resuming a genuine failure must not report Passed"
  | Tape_engine.Failed { converged; minimal; _ } ->
    check "resume: converges" converged;
    check "resume: reaches the SAME true minimum as an uninterrupted run"
      (minimal = 123_457));

  (* Resuming from an ALREADY-converged image is a no-op that still
     reports converged (nothing left to do, immediately). *)
  let converged_image =
    match converged_run with
    | Tape_engine.Failed { image; _ } -> image
    | Tape_engine.Passed _ -> assert false
  in
  (match Tape_engine.resume gen ~test ~size:10 ~budget:2000 converged_image with
  | Tape_engine.Passed _ -> failwith "expected the minimal example to still fail"
  | Tape_engine.Failed { converged; minimal; _ } ->
    (* Every pass tries a few more perturbations near an already-minimal
       example (bisection steps that fail to improve on it), but none
       are accepted, so this must still converge at the SAME value --
       resuming an already-done tape is a safe no-op, not a regression. *)
    check "resume from converged: still converged" converged;
    check "resume from converged: minimum unchanged" (minimal = 123_457));

  (* Resuming a tape that no longer reproduces a failure (the property
     changed, or this was never a real failure) is a loud, structured
     non-event, not a silent success. *)
  let passing_image =
    (* A clean, non-overrunning replay of exactly one in-range choice:
       regenerates 0 deterministically, which PASSES ([0 < 123_457]) --
       distinct from an overrun (an empty or too-short tape), which
       [resume] would also report as [Passed] but for a different
       reason (nothing to test cleanly, rather than a confirmed pass). *)
    Tape.image_of_main
      [| Tape.Integer { value = 0L; lo = 0L; hi = 1_000_000L } |]
  in
  (match Tape_engine.resume gen ~test ~size:10 ~budget:2000 passing_image with
  | Tape_engine.Passed { cases } ->
    check "resuming a non-failing tape reports Passed" (cases = 0)
  | Tape_engine.Failed _ ->
    failwith "expected Passed: the given tape does not fail the property");

  (* --- Round-tripped tape is faithful --- *)

  (* A richer image (multiple choices, matching the pair property's
     shape) exercises more than a single scalar. *)
  let pair_gen = G.both gen gen in
  let pair_test (a, b) = a + b < 100 in
  (match
     Tape_engine.run pair_gen ~test:pair_test ~seed ~count:200 ~size:10
       ~budget:2000
   with
  | Tape_engine.Passed _ -> failwith "expected a pair failure"
  | Tape_engine.Failed { image; minimal; _ } ->
    let serialized = Tape.serialize_image image in
    (match Tape.deserialize_image serialized with
    | None -> failwith "round-trip: failed to deserialize a freshly serialized image"
    | Some round_tripped ->
      (* [equal_image], not [compare_image = 0]: the latter is the
         SHRINK order, which ranks floats by distance from target and so
         cannot tell 0.0 in [0,1] from 5.0 in [5,6]. An assertion whose
         own text says "bit-for-bit" must not be tested with a preorder. *)
      check "round-trip: image is bit-for-bit identical"
        (Tape.equal_image image round_tripped);
      let replayed, () =
        Tape_engine.replay_image_and_apply pair_gen ~size:10 round_tripped
          ~f:(fun _ -> ())
      in
      check "round-trip: replay regenerates the identical value"
        ([%compare.equal: int * int] replayed minimal));

    (* The SAME round trip through the hex encoding [Tape_test] actually
       prints and accepts (Regressions' format, and resume_result's
       ~tape argument), end to end via the real user-facing wrapper. *)
    let hex = hex_of_string serialized in
    let module M = struct
      type t = int * int [@@deriving sexp_of]

      let quickcheck_generator = pair_gen
      let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
    end in
    (match
       Tape_test.resume_result
         ~f:(fun (a, b) -> if a + b >= 100 then Error "too big" else Ok ())
         ~size:10 ~tape:hex
         (module M : Base_quickcheck.Test.S with type t = int * int)
     with
    | Ok () -> failwith "expected the resumed tape to still fail"
    | Error (resumed_minimal, _) ->
      check "Tape_test.resume_result: reaches the same minimal via hex round-trip"
        ([%compare.equal: int * int] resumed_minimal minimal)));

  (* --- The printed message actually says "truncated", with a
     resumable tape a human can copy-paste --- *)
  let module M = struct
    type t = int [@@deriving sexp_of]

    let quickcheck_generator = gen
    let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
  end in
  let printed =
    capture_stdout (fun () ->
      match
        Tape_test.result
          ~f:(fun v -> if test v then Ok () else Error "too big")
          ~max_shrinks:0
          (module M : Base_quickcheck.Test.S with type t = int)
      with
      | Ok () -> failwith "expected a failure"
      | Error _ -> ())
  in
  check "truncation message says TRUNCATED"
    (String.is_substring printed ~substring:"TRUNCATED");
  check "truncation message mentions resume_run_exn"
    (String.is_substring printed ~substring:"resume_run_exn");
  check "truncation message includes a hex tape @size line"
    (String.is_substring printed ~substring:" @"
     && String.is_substring printed ~substring:"~size:");

  (* A converged run prints NOTHING truncation-related. *)
  let printed_converged =
    capture_stdout (fun () ->
      match
        Tape_test.result
          ~f:(fun v -> if test v then Ok () else Error "too big")
          (module M : Base_quickcheck.Test.S with type t = int)
      with
      | Ok () -> failwith "expected a failure"
      | Error _ -> ())
  in
  check "converged run's output does not mention truncation"
    (not (String.is_substring printed_converged ~substring:"TRUNCATED"));

  (* --- A hand-edited tape with crossed float bounds is odd data, not a
     crash (issue #11) ---

     [resume] trusts the image it is handed, and a hand-edited tape can
     carry [Float { lo > hi }]: deserialization accepts it (a
     well-formed record), but the engine's shrink-target computation
     used [Float.clamp_exn], which asserts [min <= max] -- so resuming
     such a tape died with [Assert_failure] inside [finish_from_failure]
     instead of shrinking. The clamp is now total, as [clamp_int64]
     always was.

     The crossed tape is built by editing the bounds of a REAL recorded
     tape, so the confirmation replay stays aligned and actually reaches
     the crash site; a from-scratch one-choice tape just overruns. *)
  let float_gen = G.float_inclusive 0. 10. in
  let float_test f = Float.( < ) f 5. in
  (match
     Tape_engine.run float_gen ~test:float_test ~seed:3 ~count:200 ~size:10
   with
   | Tape_engine.Passed _ -> failwith "setup: expected a float failure"
   | Tape_engine.Failed { image; _ } ->
     let crossed =
       Tape.image_of_main
         (Array.map image.Tape.main ~f:(function
            | Tape.Float { value; _ } -> Tape.Float { value; lo = 5.; hi = 2. }
            | c -> c))
     in
     (match
        Tape_engine.resume float_gen ~test:float_test ~size:10 ~budget:200
          crossed
      with
      | exception Assert_failure _ ->
        check "resume of a crossed-bounds tape: no Assert_failure" false
      | Tape_engine.Passed _ ->
        (* The replayed tape still fails the property, so resume must
           not report a pass. *)
        check "resume of a crossed-bounds tape: still fails" false
      | Tape_engine.Failed _ ->
        check "resume of a crossed-bounds tape: shrinks instead of crashing"
          true));

  (* --- A regression-entry failure prints the report too (issue #11) ---

     [Tape_test.result] returned a regression-entry failure before
     reaching [print_report], so the one failure mode with the cheapest
     reproducer was also the one with no summary line. Routed through
     the same report path now; asserted on the actual printed output,
     not the structured result, because the bug IS the missing print. *)
  let regressions_path = "test_resume_issue11_regressions.txt" in
  (match converged_run with
   | Tape_engine.Passed _ -> assert false
   | Tape_engine.Failed { image; _ } ->
     append_regression regressions_path ~image ~size:10
       ~comment:"issue 11 reproducer";
     let printed_regression =
       capture_stdout (fun () ->
         match
           Tape_test.result
             ~f:(fun v -> if test v then Ok () else Error "too big")
             ~regressions:regressions_path
             (module M : Base_quickcheck.Test.S with type t = int)
         with
         | Ok () -> failwith "expected the regression entry to fail"
         | Error _ -> ())
     in
     Stdlib.Sys.remove regressions_path;
     check "regression-entry failure prints the summary line"
       (String.is_substring printed_regression ~substring:"tapecheck:"));

  (* A saved failure can become ineligible under a new [assume]. That is a
     stale regression, not an uncaught [Invalid_example]. *)
  let assume_regressions_path = "test_resume_assume_regressions.txt" in
  (match converged_run with
   | Tape_engine.Passed _ -> assert false
   | Tape_engine.Failed { image; _ } ->
     append_regression assume_regressions_path ~image ~size:10
       ~comment:"assume-stale reproducer";
     let classified_as_stale =
       try
         ignore
           (Tape_test.result
              ~f:(fun _ ->
                Tape_test.assume false;
                Ok ())
              ~config:
                { Tape_test.default_config with
                  test_count = 0
                ; sizes = Sequence.empty
                }
              ~regressions:assume_regressions_path
              ~report:`Silent
              (module M : Base_quickcheck.Test.S with type t = int)
             : (unit, int * unit) Result.t);
         false
       with
       | Tape_stats.Invalid_example -> false
       | exn ->
         String.is_substring (Exn.to_string exn)
           ~substring:"regression tape entries replay to passing values"
     in
     Stdlib.Sys.remove assume_regressions_path;
     check "assume-rejected regression is stale, not an escaped discard"
       classified_as_stale);

  (* User-supplied examples bypass the engine's generated-case loop.  They
     must still take the same reporting exit as every other failure. *)
  let no_generated_cases =
    { Tape_test.default_config with test_count = 0; sizes = Sequence.empty }
  in
  let printed_example =
    capture_stdout (fun () ->
      match
        Tape_test.result
          ~f:(fun v -> if test v then Ok () else Error "too big")
          ~config:no_generated_cases ~examples:[ 123_457 ]
          (module M : Base_quickcheck.Test.S with type t = int)
      with
      | Ok () -> failwith "expected the explicit example to fail"
      | Error _ -> ())
  in
  check "explicit-example failure prints the summary line"
    (String.is_substring printed_example ~substring:"tapecheck:");
  check "explicit-example failure is counted"
    (String.is_substring printed_example ~substring:"1 failing");

  (* A changed generator can consume none of a saved image and still fail.
     Resume must start from the confirmation replay's normalised image, so the
     returned value, image, and structural spans describe the same execution. *)
  let stale_image =
    Tape.image_of_main
      [| Tape.Integer { value = 7L; lo = 0L; hi = 10L } |]
  in
  (match
     Tape_engine.resume (G.return 5) stale_image ~budget:0
       ~test:(fun _ -> false)
   with
   | Tape_engine.Passed _ -> failwith "normalised stale tape stopped failing"
   | Tape_engine.Failed { minimal; image; _ } ->
     check "resume keeps the replayed value" (minimal = 5);
     check "resume normalises a stale image before shrinking"
       (Array.is_empty image.Tape.main && Array.is_empty image.Tape.streams));

  Stdlib.print_endline "test_resume: all passed"

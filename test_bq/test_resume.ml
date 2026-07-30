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
      check "round-trip: image is bit-for-bit identical"
        (Tape.compare_image image round_tripped = 0);
      let replayed, () =
        Tape_engine.replay_image_and_apply pair_gen ~size:10 round_tripped
          ~f:(fun _ -> ())
      in
      check "round-trip: replay regenerates the identical value"
        ([%compare.equal: int * int] replayed minimal));

    (* The SAME round trip through the hex encoding [Tape_test] actually
       prints and accepts (Regressions' format, and resume_result's
       ~tape argument), end to end via the real user-facing wrapper. *)
    let hex = Tape_test.Regressions.hex_of_string serialized in
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

  Stdlib.print_endline "all resume tests passed"

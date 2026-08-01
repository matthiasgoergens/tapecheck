(* [Tape_test.assume] must keep working on the RESUMED path.

   The fresh-run wrappers deliberately re-raise Tape_stats.Invalid_example
   (see [try_with_preserving_assume]) so that a discard reaches the
   engine as a discard. The resumed wrappers used plain
   Or_error.try_with*, which convert it to an Error -- and the engine
   reads an Error as a test FAILURE. So a resumed shrink could accept
   and report an input the property had explicitly rejected.

   The check below is the reproducer: resume a tape that really does
   fail, but with a property that assume-rejects everything. Correct
   behaviour is "this tape no longer fails"; the bug reports a
   counterexample instead. *)
open! Base
module G = Base_quickcheck.Generator

module Int_t = struct
  type t = int

  let quickcheck_generator = G.int_uniform_inclusive 0 1_000_000
  let quickcheck_shrinker = Base_quickcheck.Shrinker.int
  let sexp_of_t = Int.sexp_of_t
end

let () =
  (* A tape that genuinely fails, obtained the ordinary way. *)
  let image =
    match
      Tape_engine.run (G.int_uniform_inclusive 0 1_000_000)
        ~test:(fun v -> v < 500_000) ~seed:7 ~count:2000 ~size:10
    with
    | Tape_engine.Passed _ -> failwith "setup: expected a failure to resume from"
    | Tape_engine.Failed { image; _ } -> image
  in
  (* Same lowercase-hex encoding [Tape_test.Regressions] uses; the
     resume entry points parse that, not the raw serialization. *)
  let tape =
    String.concat
      (List.map
         (String.to_list (Tape.serialize_image image))
         ~f:(fun c -> Printf.sprintf "%02x" (Char.to_int c)))
  in

  (* Resume it with a property that discards every input. Nothing can
     legitimately be reported: every example is invalid. *)
  let outcome =
    try
      Tape_test.resume_run_exn ~tape
        ~f:(fun (_ : int) -> Tape_test.assume false)
        (module Int_t);
      `Returned_ok
    with
    | e ->
      let msg = Exn.to_string e in
      if String.is_substring msg ~substring:"no longer fails" then `Correct
      else `Reported_failure msg
  in
  (match outcome with
   | `Correct ->
     Test_support.report "resumed assume-rejection is a discard, not a failure"
       true "raised \"no longer fails\""
   | `Returned_ok ->
     Test_support.report "resumed assume-rejection is a discard, not a failure"
       false "returned OK -- the tape should not have reproduced"
   | `Reported_failure msg ->
     Test_support.report "resumed assume-rejection is a discard, not a failure"
       false
       ("reported a counterexample from a discarded input: "
        ^ String.prefix msg 90));
  Test_support.finish ()

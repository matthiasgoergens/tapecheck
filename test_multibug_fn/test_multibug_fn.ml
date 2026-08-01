(* run_multi must return a value whose generated functions still work.

   [shrink] returns the value it happened to build during its last
   replay, on a tape that [Tape.finish] has since reset. For plain data
   that is harmless -- the value is already forced. For a value
   CONTAINING a generated function it is not: the function draws from
   its tape when called, so once the tape is reset it starts drawing
   fresh, and the reported counterexample stops behaving like the one
   that failed.

   [finish_from_failure] already avoids this on the ordinary path by
   discarding shrink's value and rebuilding with [replay_image_and_apply].
   run_multi did not.

   The check: the function in fr_minimal must agree with the function
   obtained by replaying fr_image, which is by definition the real
   counterexample. *)
open! Base
module G = Base_quickcheck.Generator

exception Boom

let gen = G.fn Base_quickcheck.Observer.int (G.int_uniform_inclusive 0 1000)

let () =
  let reports =
    Tape_engine.run_multi gen
      ~test:(fun f -> if f 0 > 100 then raise Boom)
      ~seed:99 ~count:400 ~size:10
  in
  (match reports with
   | [] -> Test_support.report "run_multi found the failure" false "no reports"
   | r :: _ ->
     Test_support.report "run_multi found the failure" true "1+ report";
     (* Same tape, replayed live: this is what the counterexample IS. *)
     let live, () =
       Tape_engine.replay_image_and_apply gen ~size:10 r.Tape_engine.fr_image
         ~f:(fun _ -> ())
     in
     let from_report = r.Tape_engine.fr_minimal 0 in
     let from_tape = live 0 in
     Test_support.report "fr_minimal's function matches its own tape"
       (from_report = from_tape)
       (Printf.sprintf "fr_minimal 0 = %d, replayed tape 0 = %d" from_report
          from_tape);
     (* And it must actually still reproduce the bug. *)
     Test_support.report "fr_minimal still exhibits the failure"
       (from_report > 100)
       (Printf.sprintf "f 0 = %d (needs > 100)" from_report));
  Test_support.finish ()

(* Pin the pre-loop trivialization attempt (issue #8).

   The engine tries ONE proposal before any pass runs: every choice set
   to its target at once. Issue #8 reported that disabling it left the
   whole suite green and the call counts unchanged, which is the profile
   of dead weight -- and the honest conclusion at the time, because no
   test in the suite had a shape that could tell the difference.

   It is not dead weight. It is the entire shrinker on this class of
   input, and the measurement is not close:

     property                     with        without
     always-fails, 40 choices     1 attempt   581 attempts, NOT minimal
     always-fails, 200 choices    1 attempt   581 attempts, NOT minimal

   Without it the run also reports converged = false, i.e. it stops
   because the budget ran out rather than because it settled.

   Why the suite missed it: every other property here fails on SOME
   inputs, so the all-targets image passes and the attempt is wasted --
   which is precisely the "no test can fail" observation. The shape that
   needs it is a property whose trivial image still fails, and there was
   not one. There is now.

   This test is deliberately cheap and deliberately extreme. [fun _ ->
   false] is the pass's best case by construction; that is the point of
   a pin, which should fail loudly the moment the mechanism goes rather
   than measure something subtle. *)
open! Base

module G = Base_quickcheck.Generator

let () =
  let failures = ref 0 in
  let check name ok detail =
    if not ok then Int.incr failures;
    Stdio.printf "  %s %-44s %s\n" (if ok then "ok  " else "FAIL") name detail
  in
  Stdio.printf "pre-loop trivialization (issue #8)\n\n";

  let length = 40 in
  (match
     Tape_engine.run
       (G.list_with_length (G.int_uniform_inclusive 0 1000) ~length)
       ~test:(fun _ -> false)
       ~seed:11 ~count:400 ~size:20
   with
   | Tape_engine.Passed _ ->
     check "a property that always fails, fails" false "no failure found"
   | Tape_engine.Failed { minimal; attempts; converged; _ } ->
     let all_zero = List.for_all minimal ~f:(fun x -> x = 0) in
     let non_zero = List.count minimal ~f:(fun x -> x <> 0) in
     check "trivial image is reached" all_zero
       (if all_zero then Printf.sprintf "%d choices, all at target" length
        else Printf.sprintf "%d of %d choices NOT at target" non_zero length);
     (* One attempt is what the mechanism costs. The bound is 10 rather
        than 1 so an unrelated extra probe does not fail the suite, and
        far below the 581 measured without the pass, so it cannot pass
        by accident. *)
     check "and reached in one attempt, not by lowering each" (attempts <= 10)
       (Printf.sprintf "%d attempts (581 without the pass)" attempts);
     check "the search settled rather than running out of budget" converged
       (Printf.sprintf "converged=%b" converged));

  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf "test_trivialization: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "test_trivialization: all passed\n"

(* Shared assertions for tests ABOUT the engine.

   Ported in spirit from Hypothesis's own test helpers
   (tests/common/debug.py, tests/common/utils.py), which have the two
   shapes this repo kept hand-rolling:

     find_any            the engine CAN find an example satisfying P
     assert_no_examples  the engine CANNOT

   Their [find_any] turns shrinking OFF and raises the example budget --
   the question is whether a failure is reachable at all, and shrinking
   only spends budget once it is.

   The scar worth copying is in their [fails_with]. They rig the PRNG
   OUTSIDE the raises block, with the comment: "so that any problems in
   rigging the PRNG don't accidentally count as the expected failure."
   An expect-failure test that passes because its own SETUP threw is
   worse than no test and reads identically. [expect_raise] below keeps
   setup outside the region whose exceptions count, for that reason.

   [find_rate] is separated from the assertions so the assertions
   themselves can be tested -- see test_support_selftest. *)
open Base

let failures = ref 0

(* Set while the self-test exercises a helper's REJECT direction: the
   inner verdict is the thing under test, and printing it as "FAIL"
   makes a passing run look broken. *)
let silence = ref false

let report name ok detail =
  if not ok then Int.incr failures;
  if not !silence then
    Stdio.printf "  %-4s %-44s %s\n" (if ok then "ok" else "FAIL") name detail

(* How often, out of [runs] independent seeds, does the engine find a
   failure at all? Shrink quality is a different question; this one is
   only about reachability. *)
let find_rate (type a) ~(gen : a Base_quickcheck.Generator.t) ~(test : a -> bool)
    ?(runs = 100) ?(count = 200) ?(size = 10) () =
  let found = ref 0 in
  for t = 0 to runs - 1 do
    match Tape_engine.run gen ~test ~seed:(t * 7919) ~count ~size with
    | Tape_engine.Failed _ -> Int.incr found
    | Tape_engine.Passed _ -> ()
  done;
  !found

(* A property that MUST be falsifiable. Guards the invisible regression:
   an engine change that quietly stops reaching a class of bug does not
   make anything red, it just makes the property "pass". *)
let find_any ~name ~gen ~test ?(runs = 100) ?count ?size ?(min_rate = 90) () =
  let found = find_rate ~gen ~test ~runs ?count ?size () in
  let pct = found * 100 / Int.max 1 runs in
  report name (pct >= min_rate)
    (Printf.sprintf "found %d/%d (need %d%%)" found runs min_rate)

(* The inverse: a property that must NOT be falsifiable. *)
let assert_no_failure ~name ~gen ~test ?(runs = 50) ?count ?size () =
  let found = find_rate ~gen ~test ~runs ?count ?size () in
  report name (found = 0) (Printf.sprintf "failed %d/%d (want 0)" found runs)

(* Assert that [f] raises. [setup] runs FIRST, outside the region whose
   exceptions are counted as the expected outcome. *)
let expect_raise ~name ?(setup = fun () -> ()) f =
  setup ();
  let raised = try f (); false with _ -> true in
  report name raised (if raised then "raised as expected" else "did NOT raise")

let finish () =
  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf "%d assertion(s) failed\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "all assertions passed\n"

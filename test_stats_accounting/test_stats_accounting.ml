(* Do the engine's own statistics match reality, on every entry point?

   This exists because MERGE-PLAN-STATS.md identified a silent failure
   mode: statistics-and-health adds counters that master's newer code
   paths -- finish_from_failure, resume, run_with_db replays, the
   determinism check -- would have to feed, and nothing in the guard
   suite would notice if they did not. The guard suite checks shrink
   quality and cost; wrong statistics pass it happily.

   Telling detail from that branch: both of its own bug fixes were
   silent-undercount bugs (assume's exception swallowed by Or_error, so
   every discard became a false failure; data_too_large unreachable via
   double-counting). The area is demonstrably prone to this.

   The check is simple and independent of what is being counted: the
   test function counts its OWN invocations, and that number must equal
   what the engine reports. Ground truth is not derived from the engine,
   which is the point -- a counter that is wrong in the same way in both
   places would otherwise agree with itself. *)
open Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name ~engine ~actual =
  if engine <> actual then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-44s engine says %d, actually %d\n" name engine actual
  end
  else Stdio.printf "  ok   %-44s %d\n" name actual

let gen = G.list (G.int_uniform_inclusive 0 1000)
let prop l = List.sum (module Int) l ~f:Fn.id < 100

(* A test function that counts its own calls, and remembers the call
   index at which it first failed -- i.e. how many calls generation
   spent before shrinking began. *)
let counting prop =
  let n = ref 0 and first_fail = ref None in
  let f x =
    Int.incr n;
    let ok = prop x in
    if (not ok) && Option.is_none !first_fail then first_fail := Some !n;
    ok
  in
  (f, n, first_fail)

let () =
  Stdio.printf "engine statistics vs ground truth\n\n";
  Stdio.printf
    "  [tests] is documented as \"true cost of a SHRINK\", so it counts\n\
    \  shrink-phase calls only -- generation is deliberately excluded.\n\
    \  These assertions check that documented meaning, not a guessed one.\n\n";

  (* 1. All passing: no shrink phase at all, so zero is correct. *)
  let n = ref 0 in
  let st = Tape_engine.no_stats () in
  let _ =
    Tape_engine.run
      (G.int_uniform_inclusive 0 10)
      ~test:(fun _ ->
        Int.incr n;
        true)
      ~seed:1 ~count:250 ~size:10 ~stats:st
  in
  check "all passing: no shrink, so tests = 0" ~engine:st.Tape_engine.tests
    ~actual:0;
  Stdio.printf "       (%d generation calls, correctly not counted)\n" !n;

  (* 2. Failing run: everything after the first failure is shrink work. *)
  let f, n, ff = counting prop in
  let st = Tape_engine.no_stats () in
  let result = Tape_engine.run gen ~test:f ~seed:7 ~count:200 ~size:10 ~stats:st in
  let gen_calls = Option.value_exn !ff in
  (* Three categories now, not two. Wiring the determinism check into the
     failure path added 8 replays per failing run: they exercise the test
     function but are NOT shrink work, so [tests] correctly excludes
     them. This assertion failed the moment the check was wired in --
     which is the test earning its place, since nothing else would have
     noticed the engine's shrink cost apparently dropping by 8. *)
  let determinism_replays = 8 in
  check "run: tests = total - generation - determinism"
    ~engine:st.Tape_engine.tests
    ~actual:(!n - gen_calls - determinism_replays);
  Stdio.printf
    "       (%d total: %d finding the failure, %d determinism replays, %d \
     shrinking)\n"
    !n gen_calls determinism_replays
    (!n - gen_calls - determinism_replays);

  (* 3. resume: generation is one confirmation replay, then shrinking. *)
  (match result with
   | Tape_engine.Failed { image; _ } ->
     let f2, n2, _ = counting prop in
     let st2 = Tape_engine.no_stats () in
     let _ = Tape_engine.resume gen ~test:f2 image ~stats:st2 in
     check "resume: tests = total - 1 confirmation"
       ~engine:st2.Tape_engine.tests ~actual:(!n2 - 1)
   | Tape_engine.Passed _ -> Stdio.printf "  (no failure to resume from)\n");

  (* 4. The determinism check makes 8 replays that are NOT shrink work,
     so they must not inflate [tests]. Pinned, because whichever way it
     goes it should be a decision. *)
  (match result with
   | Tape_engine.Failed { image; _ } ->
     let f3, n3, _ = counting prop in
     let st3 = Tape_engine.no_stats () in
     let (_ : bool) =
       Tape_engine.check_generator_determinism ~gen ~size:10 ~test:f3 image
     in
     check "determinism check does not inflate tests"
       ~engine:st3.Tape_engine.tests ~actual:0;
     Stdio.printf "       (%d replays made, none counted as shrink work)\n" !n3
   | Tape_engine.Passed _ -> ());

  (* Issue #1: the summary line must never contradict the return value.
     stats.cases_failed was incremented at ONE of four discovery sites,
     so a failure first found by the correlated-value mutation was
     counted in neither bucket -- "12 cases (12 valid, 0 discarded, 0
     failing)" on a run that returned a counterexample, with the failing
     case missing from the total too.

     The property below is the sweep from the issue, asserted rather
     than printed: two properties of identical rarity (1 in 36), one
     failing only when two draws are EQUAL -- which is exactly what the
     mutation constructs -- and one when they are unequal. Before the
     fix the equal one reported "0 failing" on 30 of 50 seeds and the
     unequal one on none. *)
  Stdio.printf "\n  issue #1: a returned failure is never reported as 0 failing\n";
  let sweep name ~test =
    let disagreed = ref 0 and found = ref 0 in
    for i = 1 to 50 do
      let st = Tape_engine.no_stats () in
      match
        Tape_engine.run
          (G.both (G.int_inclusive 0 5) (G.int_inclusive 0 5))
          ~test ~seed:i ~count:300 ~size:10 ~stats:st
      with
      | Tape_engine.Passed _ -> ()
      | Tape_engine.Failed _ ->
        Int.incr found;
        if
          String.is_substring
            (Tape_engine.stats_summary_line st)
            ~substring:"0 failing"
        then Int.incr disagreed
    done;
    let ok = !disagreed = 0 in
    if not ok then Int.incr failures;
    Stdio.printf "    %-4s %-38s %d/%d said \"0 failing\"\n"
      (if ok then "ok" else "FAIL") name !disagreed !found
  in
  sweep "fails on EQUAL draws (a=5 && b=5)" ~test:(fun (a, b) ->
    not (a = 5 && b = 5));
  sweep "fails on UNEQUAL draws (a=5 && b=0)" ~test:(fun (a, b) ->
    not (a = 5 && b = 0));

  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf
      "%d accounting failure(s). See MERGE-PLAN-STATS.md: this is the test\n\
      \  that makes merging statistics-and-health verifiable.\n"
      !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "all statistics accounted for\n"

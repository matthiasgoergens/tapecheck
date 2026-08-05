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
open Base_quickcheck.Export
module G = Base_quickcheck.Generator

module Int_t = struct
  type t = int [@@deriving quickcheck, sexp_of]
end

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

  (* Issue #7: the `Full report's three-way time split printed
     [shrink_time] but nothing ever assigned it, so every report read
     "shrink 0.0000s". The run above shrank (its property is far from
     trivial at the shrink target), so its shrink time must be
     positive. *)
  if Float.(st.Tape_engine.shrink_time > 0.) then
    Stdio.printf "  ok   %-44s %.4fs\n" "failing run: shrink_time > 0"
      st.Tape_engine.shrink_time
  else begin
    Int.incr failures;
    Stdio.printf "  FAIL %-44s %.4fs (a shrink happened; 0 is the bug)\n"
      "failing run: shrink_time > 0" st.Tape_engine.shrink_time
  end;

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

  (* Issue #1's other half: the pooled path. FIXED in this commit, and
     these are live assertions rather than a recorded observation.

     The defect: worker domains returned only "did this case fail", the
     verdict was dropped, and [run] reported [Passed {cases = 300}] while
     the statistics said 0 valid and 0 invalid -- the return value and
     the summary line contradicting each other, which is the whole
     subject of the issue. Workers cannot count it themselves ([stats] is
     plain mutable state and they would race), so the verdict is carried
     back as data and counted on the main domain.

     Three cases, because the all-passing one alone would not have caught
     a fix that counted every case as valid. *)
  Stdio.printf "\n  issue #1: pooled runs count their cases (was: none)\n";
  let pooled_counts ?(domains = 4) ~test () =
    let st = Tape_engine.no_stats () in
    let r =
      Tape_engine.run
        (G.int_uniform_inclusive 0 1_000_000)
        ~test ~seed:3 ~count:300 ~size:10 ~stats:st ~domains
    in
    let cases = match r with
      | Tape_engine.Passed { cases } -> cases
      | Tape_engine.Failed _ -> -1
    in
    (cases, st)
  in

  (* (a) All passing: every case is valid, and the two views agree. *)
  let cases, st = pooled_counts ~test:(fun _ -> true) () in
  check "pooled, all passing: valid = returned cases"
    ~engine:st.Tape_engine.cases_valid ~actual:cases;
  check "pooled, all passing: none miscounted as invalid"
    ~engine:st.Tape_engine.cases_invalid ~actual:0;

  (* (b) Half discarded via assume. Guards against a fix that simply
     counts everything as valid -- which (a) alone would accept. *)
  let _, st_d =
    pooled_counts
      ~test:(fun x ->
        Tape_stats.assume (x % 2 = 0);
        true)
      ()
  in
  let valid_d = st_d.Tape_engine.cases_valid
  and invalid_d = st_d.Tape_engine.cases_invalid in
  if valid_d > 0 && invalid_d > 0 then
    Stdio.printf "  ok   %-44s %d valid, %d discarded\n"
      "pooled, with assume: both buckets move" valid_d invalid_d
  else begin
    Int.incr failures;
    Stdio.printf
      "  FAIL %-44s %d valid, %d discarded (both must be > 0)\n"
      "pooled, with assume: both buckets move" valid_d invalid_d
  end;

  (* (c) The sequential control. If domains:1 ever reports zero, the
     comparisons above stop meaning anything -- a dead instrument reads
     as "pooled is no worse than sequential". *)
  let cases1, st1 = pooled_counts ~domains:1 ~test:(fun _ -> true) () in
  check "control: domains:1 counts its cases too"
    ~engine:st1.Tape_engine.cases_valid ~actual:cases1;

  (* Issue #1's last two paths: ?examples and ?regressions. Neither
     enters the engine's run loop, so before this a failure found by
     either returned Error while the summary said "0 cases ... 0
     failing" -- the same contradiction the sweep above guards for
     generated cases, on the two entry points the sweep cannot reach.

     This was left open as a design question ("neither runs a GENERATED
     case, so 0 is arguably honest"). Settled by noticing the invariant
     at stake is not about provenance: a returned failure must never be
     reported as 0 failing, whoever supplied the value. *)
  Stdio.printf "\n  issue #1: ?examples and ?regressions are counted too\n";

  (* All three examples pass. *)
  let st_ok = Tape_engine.no_stats () in
  let (_ : (unit, int * Error.t) Result.t) =
    Tape_test.result
      ~f:(fun v -> if v > 1_000_000 then Or_error.error_string "big" else Ok ())
      ~examples:[ 1; 2; 3 ] ~report:`Silent ~stats:st_ok
      ~config:{ Base_quickcheck.Test.default_config with test_count = 1 }
      (module Int_t)
  in
  if st_ok.Tape_engine.cases_valid >= 3 then
    Stdio.printf "  ok   %-44s %d valid (>= the 3 examples)\n"
      "examples: passing ones are counted" st_ok.Tape_engine.cases_valid
  else begin
    Int.incr failures;
    Stdio.printf "  FAIL %-44s %d valid, expected at least 3\n"
      "examples: passing ones are counted" st_ok.Tape_engine.cases_valid
  end;

  (* One example fails. The summary must not say "0 failing" while the
     call returns Error -- that is the whole issue. *)
  let st_bad = Tape_engine.no_stats () in
  let res =
    Tape_test.result
      ~f:(fun v -> if v = 7 then Or_error.error_string "boom" else Ok ())
      ~examples:[ 1; 7; 3 ] ~report:`Silent ~stats:st_bad
      ~config:{ Base_quickcheck.Test.default_config with test_count = 1 }
      (module Int_t)
  in
  let returned_failure = Result.is_error res in
  let says_zero_failing =
    String.is_substring
      (Tape_engine.stats_summary_line st_bad)
      ~substring:"0 failing"
  in
  if returned_failure && not says_zero_failing then
    Stdio.printf "  ok   %-44s %s\n" "examples: a failing one is counted"
      (Tape_engine.stats_summary_line st_bad)
  else begin
    Int.incr failures;
    Stdio.printf "  FAIL %-44s returned_failure=%b, summary=%s\n"
      "examples: a failing one is counted" returned_failure
      (Tape_engine.stats_summary_line st_bad)
  end;

  (* Issue #6: pooled SHRINK evaluations must be counted too. The pooled
     arm of [attempt_batch] dispatched proposals to worker domains and
     bumped only [attempts] -- [replays]/[tests]/[misaligns] stayed at
     zero while the shrink ran, so the `Full report's "shrink calls"
     line read 0 on exactly the runs doing the most shrink work.
     Workers cannot touch [stats] without racing (see [pool_payload] in
     the engine), so each proposal's accounting now rides back as data
     and the main domain folds it in.

     The invariant is the one the sequential path already satisfies:
     with the default realign ([`Consume], exactly one replay per
     proposal), [replays] equals [attempts]. Asserted at domains:4 with
     a domains:1 control, so a dead instrument cannot read as "pooled
     is no worse than sequential". *)
  Stdio.printf "\n  issue #6: pooled shrink evaluations are counted\n";
  let shrink_stats ~domains =
    let st = Tape_engine.no_stats () in
    match
      Tape_engine.run gen ~test:prop ~seed:7 ~count:200 ~size:10 ~stats:st
        ~domains
    with
    | Tape_engine.Passed _ -> failwith "setup: expected a failure to shrink"
    | Tape_engine.Failed { attempts; _ } -> (st, attempts)
  in
  let check_replays ~domains =
    let st, attempts = shrink_stats ~domains in
    check
      (Printf.sprintf "domains:%d: replays = attempts" domains)
      ~engine:st.Tape_engine.replays ~actual:attempts;
    if st.Tape_engine.tests > 0 then
      Stdio.printf "  ok   %-44s %d\n"
        (Printf.sprintf "domains:%d: tests behind the replays counted" domains)
        st.Tape_engine.tests
    else begin
      Int.incr failures;
      Stdio.printf "  FAIL %-44s %d (replays ran tests; 0 is the bug)\n"
        (Printf.sprintf "domains:%d: tests behind the replays counted" domains)
        st.Tape_engine.tests
    end
  in
  check_replays ~domains:4;
  check_replays ~domains:1;

  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf
      "%d accounting failure(s). See MERGE-PLAN-STATS.md: this is the test\n\
      \  that makes merging statistics-and-health verifiable.\n"
      !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "all statistics accounted for\n"

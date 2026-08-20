(* Does the engine notice when a generator's space is exhausted?

   A generator over a tiny space re-draws the same inputs for the rest of
   ~count, testing nothing. Two things are asserted: the run STOPS early
   on a small space, and it does NOT stop early on a large one -- a
   detector that always fires would silently truncate real runs, which is
   far worse than the waste it set out to fix. *)
open Base
module G = Base_quickcheck.Generator

let calls_for (type a) ~(gen : a G.t) ~count =
  let n = ref 0 in
  let (_ : a Tape_engine.result) =
    Tape_engine.run gen
      ~test:(fun _ ->
        Int.incr n;
        true)
      ~seed:1 ~count ~size:10
  in
  !n

let () =
  let count = 500 in
  let tiny = calls_for ~gen:G.bool ~count in
  let small = calls_for ~gen:(G.int_uniform_inclusive 0 5) ~count in
  let big = calls_for ~gen:(G.int_uniform_inclusive 0 1_000_000) ~count in
  Stdio.printf "with ~count:%d\n" count;
  Stdio.printf "  bool          (2 values)   %4d cases run\n" tiny;
  Stdio.printf "  int 0..5      (6 values)   %4d cases run\n" small;
  Stdio.printf "  int 0..1e6    (huge)       %4d cases run\n" big;
  let stops_tiny = tiny < count in
  let stops_small = small < count in
  let runs_big = big = count in
  Stdio.printf "\n  stops early on a 2-value space:   %b\n" stops_tiny;
  Stdio.printf "  stops early on a 6-value space:   %b\n" stops_small;
  Stdio.printf "  does NOT truncate a huge space:   %b\n" runs_big;

  (* Issue #11: an early-stopped run must report the cases it actually
     RAN, not ~count. Before the fix, [G.bool] with ~count:200 stopped
     after 66 cases and still returned [Passed {cases = 200}] while the
     summary line said 66 valid -- the run's own outputs contradicting
     each other. *)
  let n = ref 0 in
  let st = Tape_engine.no_stats () in
  let honest =
    match
      Tape_engine.run G.bool
        ~test:(fun _ ->
          Int.incr n;
          true)
        ~seed:1 ~count:200 ~size:10 ~stats:st
    with
    | Tape_engine.Failed _ -> false
    | Tape_engine.Passed { cases } ->
      let snapshot = Tape_engine.stats_snapshot st in
      Stdio.printf
        "     (returned {cases = %d}; actually ran %d; stats say %d valid)\n"
        cases !n snapshot.cases_valid;
      cases = !n && cases = snapshot.cases_valid
  in
  Stdio.printf "  early stop reports cases RUN, not ~count: %b\n" honest;
  if not (stops_tiny && stops_small && runs_big && honest) then begin
    Stdio.printf "\nFAIL\n";
    Stdlib.exit 1
  end;
  Stdio.printf "\nexhaustion detected without truncating real runs\n"

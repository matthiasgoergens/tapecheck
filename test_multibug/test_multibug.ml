(* Does run_multi find SEVERAL distinct bugs in one run, and minimise
   each without letting one collapse into another?

   The failure this guards is specific: shrinking bug A can "slip" into
   a smaller bug B, at which point A is lost and the run reports one bug
   where there were two. That is why shrinking is done under an
   origin-preserving predicate. A test that only counted bugs found
   during GENERATION would not notice the slip, so this checks the
   minimised results too. *)
open Base
module G = Base_quickcheck.Generator

exception Too_big of int
exception Odd_one of int

let () =
  (* Two independent bugs, deliberately at different thresholds so the
     smaller one is a tempting slip target for the larger. *)
  let prop v =
    if v >= 500 then raise (Too_big v);
    if v >= 100 && v % 2 = 1 then raise (Odd_one v)
  in
  let reports =
    Tape_engine.run_multi
      (G.int_uniform_inclusive 0 1000)
      ~test:prop ~seed:4 ~count:400 ~size:10
  in
  Stdio.printf "distinct bugs found: %d\n\n" (List.length reports);
  List.iter reports ~f:(fun r ->
    Stdio.printf "  %-28s minimal %-6d (%d attempts)  %s\n"
      r.Tape_engine.fr_origin.Tape_engine.exn_name r.Tape_engine.fr_minimal
      r.Tape_engine.fr_attempts r.Tape_engine.fr_origin.Tape_engine.loc);
  let names =
    List.map reports ~f:(fun r ->
      r.Tape_engine.fr_origin.Tape_engine.exn_name)
    |> Set.of_list (module String)
  in
  let both = Set.length names = 2 in
  (* Each bug must minimise to ITS OWN threshold, not to the other's.
     Too_big -> 500; Odd_one -> 101 (smallest odd >= 100). If shrinking
     slipped, one of these would carry the other's minimum. *)
  let correct =
    List.for_all reports ~f:(fun r ->
      let n = r.Tape_engine.fr_minimal in
      match r.Tape_engine.fr_origin.Tape_engine.exn_name with
      | s when String.is_substring s ~substring:"Too_big" -> n = 500
      | s when String.is_substring s ~substring:"Odd_one" -> n = 101
      | _ -> false)
  in
  Stdio.printf "\n  both distinct bugs reported:        %b\n" both;
  Stdio.printf "  each minimised to its OWN threshold: %b\n" correct;
  if not (both && correct) then begin
    Stdio.printf "\nFAIL: expected Too_big->500 and Odd_one->101\n";
    Stdlib.exit 1
  end;
  let discard_reports =
    Tape_engine.run_multi
      (G.int_uniform_inclusive 0 1000)
      ~test:(fun _ -> Tape_stats.assume false)
      ~seed:9 ~count:50 ~size:10
  in
  if not (List.is_empty discard_reports) then begin
    Stdio.printf "\nFAIL: assume-rejected cases were reported as bugs\n";
    Stdlib.exit 1
  end;
  Stdio.printf "  assume-rejected cases reported as bugs: false\n";
  Stdio.printf "\nmulti-bug reporting works; no origin slipped\n"

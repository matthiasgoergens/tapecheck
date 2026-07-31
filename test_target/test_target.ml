(* Does run_target actually climb?

   The failure mode to guard against is a hill climber that reports a
   score without having improved on its starting point -- which would
   look like success and be worthless. So every case checks the score
   MOVED, not merely that a number came back. *)
open Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name ~start ~final ~want_at_least =
  let ok = Float.( >= ) final want_at_least && Float.( > ) final start in
  if not ok then Int.incr failures;
  Stdio.printf "  %-4s %-38s %.0f -> %.0f (want >= %.0f)\n"
    (if ok then "ok" else "FAIL") name start final want_at_least

let () =
  Stdio.printf "targeted PBT: does the hill climber climb?\n\n";

  (* 1. Maximise a single integer. The optimum is the range maximum. *)
  let gen = G.int_uniform_inclusive 0 10_000 in
  let objective v = Float.of_int v in
  let v0, _, _ =
    Tape_engine.run_target gen ~objective ~seed:1 ~size:10 ~budget:0
  in
  let v, score, attempts =
    Tape_engine.run_target gen ~objective ~seed:1 ~size:10
  in
  check "single int, maximise" ~start:(Float.of_int v0) ~final:score
    ~want_at_least:9000.;
  Stdio.printf "       (%d attempts, final value %d)\n" attempts v;

  (* 2. Maximise a sum over a list -- several choices must move. *)
  let gen = G.list (G.int_uniform_inclusive 0 1000) in
  let objective l = Float.of_int (List.sum (module Int) l ~f:Fn.id) in
  (* Pick a seed whose initial draw is non-empty. run_target EDITS
     existing choices; it cannot grow the tape, so an empty starting
     list has nothing to climb. Hypothesis's optimiser can extend the
     buffer (its __extend field); ours cannot, and that is a real
     limitation rather than a bad seed -- recorded at run_target. *)
  let seed =
    List.find_exn [ 7; 11; 13; 17; 19; 23 ] ~f:(fun sd ->
      let l, _, _ =
        Tape_engine.run_target gen ~objective ~seed:sd ~size:10 ~budget:0
      in
      not (List.is_empty l))
  in
  let l0, _, _ =
    Tape_engine.run_target gen ~objective ~seed ~size:10 ~budget:0
  in
  let l, score, attempts =
    Tape_engine.run_target gen ~objective ~seed ~size:10
  in
  check "list sum, maximise" ~start:(objective l0) ~final:score
    ~want_at_least:(objective l0 +. 1.);
  Stdio.printf "       (%d attempts, %d elements, sum %.0f)\n" attempts
    (List.length l) score;

  (* 3. A plateau: the score ignores everything but a threshold, so a
     strict climber stalls. This is what the lateral-move rule is for. *)
  let gen = G.int_uniform_inclusive 0 10_000 in
  let objective v = if v > 5000 then 100. else Float.of_int v /. 1000. in
  let v0, _, _ =
    Tape_engine.run_target gen ~objective ~seed:3 ~size:10 ~budget:0
  in
  let _, score, _ = Tape_engine.run_target gen ~objective ~seed:3 ~size:10 in
  check "plateau (threshold objective)" ~start:(objective v0) ~final:score
    ~want_at_least:100.;

  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf "%d target failure(s)\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "hill climber improves on its starting point in every case\n"

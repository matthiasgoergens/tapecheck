(* Does Hypothesis's per-draw performance scar transfer to us?

   Their comment (datatree.py:325):
     "we skip a hash set lookup on every draw and that's a pretty niche
      failure mode"

   i.e. they declined a correctness check to avoid one hash lookup per
   DRAW. Whether that trade is right for tapecheck depends on the ratio
   of a hash lookup to a draw, and that ratio is language-dependent in
   the direction opposite to my first guess: the FASTER draws are, the
   BIGGER a fixed-cost lookup looms.

   Measures both sides directly. *)
open Base
module G = Base_quickcheck.Generator

let time_it name n f =
  let t0 = Unix.gettimeofday () in
  f ();
  let t1 = Unix.gettimeofday () in
  let per = (t1 -. t0) /. Float.of_int n *. 1e9 in
  Stdio.printf "  %-34s %8.1f ns each\n" name per;
  per

let () =
  let n = 3_000_000 in
  (* A hash set lookup of the shape they describe: "is index i forced?" *)
  let tbl = Hashtbl.Poly.create () in
  for i = 0 to 999 do
    Hashtbl.set tbl ~key:i ~data:()
  done;
  let sink = ref 0 in
  let hash_ns =
    time_it "Hashtbl lookup (int key)" n (fun () ->
      for i = 0 to n - 1 do
        if Option.is_some (Hashtbl.find tbl (i % 1000)) then Int.incr sink
      done)
  in
  (* Cost of one recorded draw, measured through the tape. *)
  let draws = 200_000 in
  let gen = G.int_uniform_inclusive 0 1_000_000 in
  let draw_ns =
    time_it "one recorded tape draw" draws (fun () ->
      for t = 0 to (draws / 100) - 1 do
        ignore
          (Tape_engine.run gen
             ~test:(fun _ -> true)
             ~seed:t ~count:100 ~size:10
            : int Tape_engine.result)
      done)
  in
  Stdio.printf "\n  hash lookup as a fraction of one draw: %.1f%%\n"
    (100. *. hash_ns /. draw_ns);
  Stdio.printf "  (sink %d, kept so the loop is not optimised away)\n" !sink

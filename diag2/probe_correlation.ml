(* Does tapecheck struggle to FIND bugs that need correlated values?

   Parity review #3: Hypothesis mutates by structurally duplicating
   equivalent spans, "to produce correlated or repeated values that
   random sampling rarely finds". tapecheck generates from independent
   seeds and has no such mutator.

   Measured before building one: properties whose failure requires two
   values to COINCIDE. Independent sampling should find these rarely,
   and the rarity should worsen as the value range grows. *)
open Base
module G = Base_quickcheck.Generator

let rate ~name ~gen ~test =
  let found = ref 0 in
  for t = 0 to 199 do
    match
      Tape_engine.run gen ~test ~seed:(t * 7919) ~count:200 ~size:10
    with
    | Tape_engine.Failed _ -> Int.incr found
    | Tape_engine.Passed _ -> ()
  done;
  Stdio.printf "  %-46s found in %3d/200 runs\n" name !found

let has_dup l =
  let rec go = function
    | [] | [ _ ] -> false
    | x :: rest -> List.mem rest x ~equal:Int.equal || go rest
  in
  go l

let () =
  Stdio.printf "finding bugs that need values to COINCIDE\n\n";
  List.iter [ 10; 100; 1000; 100_000 ] ~f:(fun hi ->
    rate
      ~name:(Printf.sprintf "duplicate in list, elements 0..%d" hi)
      ~gen:(G.list (G.int_uniform_inclusive 0 hi))
      ~test:(fun l -> not (has_dup l)));
  Stdio.printf "\n";
  List.iter [ 10; 100; 1000; 100_000 ] ~f:(fun hi ->
    rate
      ~name:(Printf.sprintf "pair with a = b, each 0..%d" hi)
      ~gen:(G.both (G.int_uniform_inclusive 0 hi) (G.int_uniform_inclusive 0 hi))
      ~test:(fun (a, b) -> a <> b))

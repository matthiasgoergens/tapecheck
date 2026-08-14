open! Base
module G = Base_quickcheck.Generator

let check name cond = if not cond then failwith ("FAILED: " ^ name)

(* The normalisation property of reorder_spans: two sibling slots
   wrapped in reorderable spans inside a reorderable parent, with a
   pass-predicate that fails on sum >= 15. The tape-shortlex minimal
   failing counterexample is (0, 20) — 20 is the boundary value with a
   two-entry recording, so it is cheaper to encode than 15 — and the
   sorted arrangement puts 0's two-entry slice before 20's, so every
   seed must canonicalise to (0, 20); without the pass some seeds
   settle on (20, 0). *)
let () =
  let reordered_slots =
    G.with_reorderable_span
      (G.map
         (G.both
            (G.with_reorderable_span (G.int_inclusive 0 20))
            (G.with_reorderable_span (G.int_inclusive 0 20)))
         ~f:(fun (a, b) -> a, b))
  in
  for seed = 0 to 19 do
    match
      Tape_engine.run ~seed ~count:200 reordered_slots
        ~test:(fun (a, b) -> a + b < 15)
    with
    | Tape_engine.Passed _ -> failwith "no failure found"
    | Tape_engine.Failed { minimal; _ } ->
      check "reorder canonicalises the sibling slots"
        (Poly.equal (minimal : int * int) (0, 20))
  done;
  Stdio.printf "test_reorder: all assertions passed\n"

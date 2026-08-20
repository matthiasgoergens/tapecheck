open! Base
module G = Base_quickcheck.Generator

let check name cond detail =
  if not cond then failwith (Printf.sprintf "FAILED: %s (%s)" name detail)

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
        (Poly.equal (minimal : int * int) (0, 20)) "two-slot case"
  done;
  (* NORMALISATION, which is what the pass is actually for, and the
     property a mutation experiment showed nothing else pins. Five
     symmetric slots, as in the bound5 challenge: the pass must
     canonicalise the answer set onto ~one arrangement. Corrupting the
     interval reconstruction (advancing the cursor to a child's start
     rather than its stop) leaves every other test in the suite green
     while the distinct-answer count goes 1 -> 17, because replay
     re-records and quietly repairs the malformed proposal; only the
     spread of answers shows it. Note the trap: EXACT matches go UP
     under that bug, from 0 to 44 of 200, since without
     canonicalisation some runs hit the expected permutation by luck.
     Guarding exactness would have rewarded the defect. *)
  let slot () = G.with_reorderable_span (G.list_with_length (G.int_inclusive 0 40) ~length:1) in
  let five =
    G.with_reorderable_span
      (G.map
         (G.both (G.both (slot ()) (slot ()))
            (G.both (slot ()) (G.both (slot ()) (slot ()))))
         ~f:(fun ((a, b), (c, (d, e))) -> [ a; b; c; d; e ]))
  in
  let answers = Hashtbl.create (module String) in
  let found = ref 0 in
  for seed = 0 to 119 do
    match
      Tape_engine.run ~seed ~count:400 five
        ~test:(fun ls ->
          List.sum (module Int) ls ~f:(fun l -> List.sum (module Int) l ~f:Fn.id) < 30)
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; _ } ->
      Int.incr found;
      let key =
        String.concat ~sep:"|"
          (List.map minimal ~f:(fun l ->
             String.concat ~sep:"," (List.map l ~f:Int.to_string)))
      in
      Hashtbl.set answers ~key ~data:()
  done;
  let distinct = Hashtbl.length answers in
  (* Correct: 1 distinct. Corrupted reconstruction: 3. The bound is 2
     so it sits between them -- a bound of 3 passes under the bug,
     which is how the first draft of this guard failed its kill-test. *)
  check "reorder canonicalises five symmetric slots" (distinct <= 2)
    (Printf.sprintf "%d distinct answers over %d failures" distinct !found);
  check "  ^ was not vacuous" (!found > 100)
    (Printf.sprintf "%d/120 seeds failed" !found);
  Stdio.printf "test_reorder: all assertions passed (%d distinct answers)\n" distinct

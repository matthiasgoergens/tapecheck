(* Port of Hypothesis's tests/quality/test_poisoned_trees.py.

   The sharpest shrink-quality test in their suite, and the one that
   measures the capability we are missing. A binary tree of leaves; one
   leaf is "poisoned" with a value that fresh generation reaches with
   probability 2^-32, so the shrinker cannot re-find it and must instead
   PRESERVE it while discarding everything around it. Do that from every
   leaf position in turn and you have tested that the engine can replace
   a whole structure by an arbitrary one of its descendants.

   Three details of theirs are load-bearing and are kept:

   - The leaf value is drawn as two 16-bit halves, not one 32-bit draw.
     Their comment: as a single block, "the heuristics that allow us to
     move blocks around would fire and it would move right, which would
     then allow us to shrink it more easily". They deliberately closed
     the easy route so the test measures the hard one.

   - A marker must survive. Without it, truncating the tape after the
     poisoned leaf is a valid shrink and the test passes for a reason
     that has nothing to do with descending into a subtree.

   - Poison is injected at EVERY leaf position, not just one. The first
     and last positions are the easy cases; interior ones are not.

   In Hypothesis this route is [pass_to_descendant], which needs spans.
   We record at the PRNG layer and have no spans (SPANS-THE-ROOT-CAUSE.md),
   so this file exists to say how much that costs, in a number.

   Measured 2026-08-01, same three sizes and two seeds as theirs, so the
   same 34 leaf positions:

     Hypothesis 6.152.9   34/34   (their own test, 6 cases, all pass)
     tapecheck            12/34   (10/34 when first measured; the two
                                   extra positions came with later
                                   shrink passes, re-measured 2026-08-08)

   And the failure has a shape rather than being noise. Positions 0 and
   1 reduce fully; from position 2 on, the surviving tree grows
   monotonically with how deep the poison sits in the tape -- for the
   10-leaf tree, 4,5,6,8,10,10,10,10 leaves left. Poison early in the
   tape can be isolated by deleting what follows it. Poison late cannot,
   because isolating it means deleting what PRECEDES it, and that shifts
   the poison's own two draws into the position where a branch coin is
   read. They get re-parsed as structure and the poison is destroyed.
   Span boundaries are exactly what would let the subtree be relocated
   intact; that is the whole of the gap, and this is its size. *)
open Base
module G = Base_quickcheck.Generator

let max16 = 65535
let marker_value = 3

type tree =
  | Leaf of bool (* poisoned *)
  | Node of tree * tree

let rec leaves = function
  | Leaf p -> [ p ]
  | Node (l, r) -> leaves l @ leaves r

let leaf_count t = List.length (leaves t)
let has_poison t = List.exists (leaves t) ~f:Fn.id

let leaf_gen =
  G.map
    (G.both (G.int_uniform_inclusive 0 max16) (G.int_uniform_inclusive 0 max16))
    ~f:(fun (hi, lo) -> Leaf (hi = max16 && lo = max16))

(* Branch with probability p, to depth [max_depth]. Hypothesis's
   strategy is unbounded and relies on the coin to terminate; we bound
   the depth so a pathological tape cannot diverge. *)
let tree_gen ~p ~max_depth =
  let threshold = Float.to_int (p *. 1000.) in
  let rec go depth =
    if depth <= 0 then leaf_gen
    else
      (* Branch on HIGH values, so the minimal choice (0) terminates.
         With the comparison the other way the minimal tape is a full
         tree of depth [max_depth] -- which the engine's own
         large_base_example health check caught on the first run. *)
      G.bind (G.int_uniform_inclusive 0 999) ~f:(fun c ->
        if c >= 1000 - threshold then
          G.map
            (G.both
               (G.of_lazy (lazy (go (depth - 1))))
               (G.of_lazy (lazy (go (depth - 1)))))
            ~f:(fun (l, r) -> Node (l, r))
        else leaf_gen)
  in
  go max_depth

(* The marker is drawn after the tree and must equal its MAXIMUM, so
   shrinking cannot reach it by reduction and truncation destroys it. *)
let gen ~p ~max_depth =
  G.both (tree_gen ~p ~max_depth) (G.int_uniform_inclusive 0 marker_value)

let is_leaf_draw = function
  | Tape.Integer { hi; _ } -> Int64.equal hi (Int64.of_int max16)
  | _ -> false

(* Leaf starts: pairs of consecutive 16-bit draws. Their version reads
   these off [data.blocks]; the choice tape is typed, so the draw's own
   bounds identify it and no span metadata is needed. *)
let leaf_starts (img : Tape.image) =
  let m = img.Tape.main in
  let n = Array.length m in
  let rec go i acc =
    if i + 1 >= n then List.rev acc
    else if is_leaf_draw m.(i) && is_leaf_draw m.(i + 1) then
      go (i + 2) (i :: acc)
    else go (i + 1) acc
  in
  go 0 []

(* Set a draw to its maximum. Encoding-agnostic: the recorded choice
   carries its own bounds. *)
let maxed = function
  | Tape.Integer { lo; hi; _ } -> Tape.Integer { value = hi; lo; hi }
  | c -> c

let poison_at (img : Tape.image) u =
  let m = Array.copy img.Tape.main in
  m.(u) <- maxed m.(u);
  m.(u + 1) <- maxed m.(u + 1);
  { img with Tape.main = m }

let replay (img : Tape.image) ~p ~max_depth =
  let tape = Tape.create () in
  Tape.start_replay_image tape img;
  let random = Splittable_random.For_tape.attach (Splittable_random.of_int 0) tape in
  let v = Base_quickcheck.Generator.generate (gen ~p ~max_depth) ~size:10 ~random in
  ignore (Tape.finish tape : Tape.output);
  v

(* Step A: a minimal tree of exactly [size] leaves with the marker set.
   Same shape as theirs -- ask for "at least size", let shrinking bring
   it down to the boundary. *)
let base_tree ~size ~seed =
  let p = 1.0 /. (2.0 -. (1.0 /. Float.of_int size)) in
  let max_depth = 12 in
  let test (t, m) = not (leaf_count t >= size && m = marker_value) in
  match
    Tape_engine.run (gen ~p ~max_depth) ~test ~seed ~count:3000 ~size:10
      ~budget:20_000
  with
  | Tape_engine.Passed _ -> None
  | Tape_engine.Failed { image; minimal = t, _; _ } -> Some (image, t, p, max_depth)

let run_size ~size ~seed =
  match base_tree ~size ~seed with
  | None ->
    Stdio.printf "  size %d seed %d: could not build a base tree\n" size seed;
    None
  | Some (img, t, p, max_depth) ->
    let starts = leaf_starts img in
    let ok = ref 0 and total = ref 0 in
    let wins = ref [] and losses = ref [] in
    List.iteri starts ~f:(fun idx u ->
      let poisoned = poison_at img u in
      (* Only count positions where the splice actually creates poison;
         a position that does not is not a leaf we can test. *)
      let pt, pm = replay poisoned ~p ~max_depth in
      if has_poison pt && pm = marker_value then begin
        Int.incr total;
        let test (t, m) = not (has_poison t && m = marker_value) in
        match
          Tape_engine.resume (gen ~p ~max_depth) ~test poisoned ~budget:20_000
            ~max_shrinks:5000
        with
        | Tape_engine.Passed _ -> ()
        | Tape_engine.Failed { minimal = mt, mm; _ } ->
          if leaf_count mt = 1 && has_poison mt && mm = marker_value then begin
            Int.incr ok;
            wins := idx :: !wins
          end
          else losses := (idx, leaf_count mt) :: !losses
      end);
    Stdio.printf "  size %-2d seed %-3d: base has %d leaves, poison reduced to a\
                 \ single leaf from %d/%d positions\n"
      size seed (leaf_count t) !ok !total;
    if not (List.is_empty !wins) then
      Stdio.printf "      leaf positions that reduced fully: %s\n"
        (String.concat ~sep:"," (List.map (List.rev !wins) ~f:Int.to_string));
    if not (List.is_empty !losses) then
      Stdio.printf "      stuck at (position:leaves): %s\n"
        (String.concat ~sep:" "
           (List.map (List.rev !losses) ~f:(fun (i, n) ->
              Printf.sprintf "%d:%d" i n)));
    Some (!ok, !total)

let () =
  Stdio.printf "poisoned trees (Hypothesis tests/quality/test_poisoned_trees.py):\n";
  let results =
    List.concat_map [ 2; 5; 10 ] ~f:(fun size ->
      List.filter_map [ 0; 1 ] ~f:(fun seed -> run_size ~size ~seed))
  in
  let ok = List.sum (module Int) results ~f:fst in
  let total = List.sum (module Int) results ~f:snd in
  Stdio.printf "\n  overall: %d/%d\n\n" ok total;
  (* The floor is a recorded measurement, not an aspiration. Hypothesis
     passes this at 34/34; we measured 12/34. The assertion exists so
     the number cannot silently get worse -- and so that if it gets
     BETTER, someone is told, because that would mean a pass landed that
     we did not think we had.

     Raised 10 -> 12 on 2026-08-08 (issue #12). The NOTE below had been
     firing on every run since the passes that earned the extra two
     positions landed, which is the failure mode this whole file exists
     to avoid: a guard that prints "raise the floor" indefinitely is
     protecting the OLD number, so a regression from 12 back to 10 would
     have passed silently. *)
  Test_support.report "poison-position rate has not regressed" (ok >= 12)
    (Printf.sprintf "%d/%d (floor 12, Hypothesis 34/34)" ok total);
  Test_support.report "the benchmark actually ran" (total = 34)
    (Printf.sprintf "%d testable positions (expected 34)" total);
  if ok > 12 then
    Stdio.printf
      "\n  NOTE: %d/%d beats the recorded 12/34. If a shrink pass changed,\n\
      \        raise the floor and update the header measurement.\n"
      ok total;
  Test_support.finish ~name:"test_poison" ()

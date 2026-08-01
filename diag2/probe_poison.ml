(* How many choices does one tree leaf consume, and can a leaf be
   poisoned by maxing its draws? Groundwork for porting Hypothesis's
   test_poisoned_trees. *)
open Base
module G = Base_quickcheck.Generator

let max16 = 65535

type tree = Leaf of bool

(* Two 16-bit halves rather than one 32-bit draw, exactly as Hypothesis
   does it: a single block would let block-move heuristics fire and make
   the shrink easy for the wrong reason. *)
let leaf_gen =
  G.map
    (G.both (G.int_uniform_inclusive 0 max16) (G.int_uniform_inclusive 0 max16))
    ~f:(fun (hi, lo) -> Leaf (hi = max16 && lo = max16))

let describe (c : Tape.choice) =
  match c with
  | Tape.Integer { value; lo; hi } ->
    Printf.sprintf "Int %Ld [%Ld,%Ld]" value lo hi
  | Tape.Float { value; _ } -> Printf.sprintf "Float %f" value
  | Tape.Bool b -> Printf.sprintf "Bool %b" b
  | Tape.Marker -> "Marker"

let record gen seed =
  let tape = Tape.create () in
  Tape.start_recording tape;
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
  in
  let v = Base_quickcheck.Generator.generate gen ~size:10 ~random in
  let out = Tape.finish tape in
  (v, out.Tape.image)

let () =
  for seed = 0 to 4 do
    let v, img = record leaf_gen seed in
    let poisoned = match v with Leaf p -> p in
    Stdio.printf "leaf seed %d: %d choices, poisoned=%b  [%s]\n" seed
      (Array.length img.Tape.main) poisoned
      (String.concat ~sep:"; " (Array.to_list (Array.map img.Tape.main ~f:describe)))
  done

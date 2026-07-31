(* Is run_target's growth move ineffective in general, or only under
   base_quickcheck's list encoding?

   Growth appends a copy of the last choice and lets replay read it. For
   that to add a LIST ELEMENT, the encoding has to be one where a
   trailing choice means "another element" -- which a continuation-bool
   encoding is and a size-class-then-length encoding is not, since the
   length was decided earlier. Same root cause as self_len. *)
open Base
module G = Base_quickcheck.Generator

let list_cont elt =
  G.create (fun ~size ~random ->
    let rec go acc k =
      if k <= 0 then List.rev acc
      else if Splittable_random.int random ~lo:0 ~hi:3 = 0 then List.rev acc
      else
        let v = G.generate elt ~size ~random in
        go (v :: acc) (k - 1)
    in
    go [] 24)

let objective l = Float.of_int (List.sum (module Int) l ~f:Fn.id)

let try_gen ~name ~gen =
  let grew = ref 0 and n = ref 0 in
  for seed = 0 to 29 do
    let l0, _, _ = Tape_engine.run_target gen ~objective ~seed ~size:10 ~budget:0 in
    let l1, _, _ = Tape_engine.run_target gen ~objective ~seed ~size:10 ~budget:400 in
    Int.incr n;
    if List.length l1 > List.length l0 then Int.incr grew
  done;
  Stdio.printf "  %-24s grew in %2d of %d runs\n" name !grew !n

let () =
  Stdio.printf "does the growth move add list elements?\n\n";
  let elt = G.int_uniform_inclusive 0 1000 in
  try_gen ~name:"G.list (size-class)" ~gen:(G.list elt);
  try_gen ~name:"continuation-bool list" ~gen:(list_cont elt)

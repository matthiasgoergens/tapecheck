(* How many tape choices does base_quickcheck's list generator spend per
   element? sizes (generator.ml:345) draws once per unit of size budget
   to decide element sizes, plus a permutation pass, so the count may be
   O(size) rather than O(length). Measured rather than asserted. *)
open Base
module G = Base_quickcheck.Generator

let count_choices (img : Tape.image) =
  Array.length img.Tape.main
  + Array.fold img.Tape.streams ~init:0 ~f:(fun a (_, c) -> a + Array.length c)

let probe ~name ~gen ~size =
  (* Force a failure immediately so we capture the ORIGINAL tape. *)
  let total = ref 0 and n = ref 0 and elems = ref 0 in
  for t = 0 to 199 do
    match
      Tape_engine.run gen ~test:(fun _ -> false) ~seed:(t * 7919) ~count:1 ~size
        ~budget:0
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { original; image; _ } ->
      Int.incr n;
      total := !total + count_choices image;
      elems := !elems + List.length original
  done;
  if !n > 0 then
    Stdio.printf
      "  size %3d: %5.1f choices, %4.1f elements, %5.2f choices/element\n" size
      (Float.of_int !total /. Float.of_int !n)
      (Float.of_int !elems /. Float.of_int !n)
      (Float.of_int !total /. Float.of_int (Int.max 1 !elems));
  ignore name

let () =
  Stdio.printf "int list, draws per element as ~size grows\n";
  List.iter [ 1; 3; 5; 10; 20; 40; 80 ] ~f:(fun size ->
    probe ~name:"list" ~gen:(G.list (G.int_uniform_inclusive 0 1000)) ~size)

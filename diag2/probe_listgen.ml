(* Prototype: would a shrink-friendlier list encoding actually help?

   Measured earlier: G.list costs 4.72 tape choices per element and
   15.46 when nested, because [sizes] (generator.ml:345) draws once per
   unit of size budget and then permutes. Records and hand-written
   recursive generators sit at 1.0-1.2. So the overhead is one
   combinator's, and the obvious question is whether replacing it buys
   anything beyond a smaller tape.

   Two alternative encodings, both trivial:

     list_len   draw the length once, then that many elements.
     list_cont  draw a continuation bool before each element, which is
                what Hypothesis's lists() does -- deleting an element is
                then a local edit, and flipping a bool truncates.

   Compared on tape size AND on the three list benchmarks, because a
   smaller tape that shrinks worse is not an improvement. self_len is
   the interesting one: its 47/100 was diagnosed as a generator-encoding
   limit, so if the diagnosis is right a better encoding should move it. *)
open Base
module G = Base_quickcheck.Generator

let list_len elt =
  let open G.Let_syntax in
  let%bind n = G.int_uniform_inclusive 0 12 in
  G.list_with_length elt ~length:n

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

let count img =
  Array.length img.Tape.main
  + Array.fold img.Tape.streams ~init:0 ~f:(fun a (_, c) -> a + Array.length c)

let tape_cost ~name ~gen =
  let choices = ref 0 and units = ref 0 and n = ref 0 in
  for t = 0 to 199 do
    match
      Tape_engine.run gen ~test:(fun _ -> false) ~seed:(t * 7919) ~count:1
        ~size:10 ~budget:0
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { image; original; _ } ->
      Int.incr n;
      choices := !choices + count image;
      units := !units + List.length original
  done;
  let c = Float.of_int !choices /. Float.of_int (Int.max 1 !n) in
  let u = Float.of_int !units /. Float.of_int (Int.max 1 !n) in
  Stdio.printf "  %-12s %5.1f choices, %4.1f elements, %5.2f per element\n" name
    c u (c /. Float.max 1. u)

let quality ~name ~gen ~test ~is_minimal =
  let found = ref 0 and minimal = ref 0 and calls = ref 0 in
  for t = 0 to 99 do
    match
      Tape_engine.run gen ~test ~seed:(t * 1_000_003) ~count:200 ~size:10
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; attempts; _ } ->
      Int.incr found;
      calls := !calls + attempts;
      if is_minimal m then Int.incr minimal
  done;
  Stdio.printf "    %-12s found %3d, minimal %3d, %4d calls\n" name !found
    !minimal (!calls / 100)

let () =
  let elt = G.int_uniform_inclusive 0 100 in
  let elt1000 = G.int_uniform_inclusive 0 1000 in
  Stdio.printf "TAPE COST\n";
  tape_cost ~name:"G.list" ~gen:(G.list elt);
  tape_cost ~name:"list_len" ~gen:(list_len elt);
  tape_cost ~name:"list_cont" ~gen:(list_cont elt);
  Stdio.printf "\nSHRINK QUALITY\n";
  Stdio.printf "  length >= 3 (minimal [0;0;0])\n";
  let t3 l = List.length l < 3 in
  let m3 l = List.equal Int.equal l [ 0; 0; 0 ] in
  quality ~name:"G.list" ~gen:(G.list elt) ~test:t3 ~is_minimal:m3;
  quality ~name:"list_len" ~gen:(list_len elt) ~test:t3 ~is_minimal:m3;
  quality ~name:"list_cont" ~gen:(list_cont elt) ~test:t3 ~is_minimal:m3;
  Stdio.printf "  sum >= 100 (minimal [100])\n";
  let ts l = List.sum (module Int) l ~f:Fn.id < 100 in
  let ms l = List.equal Int.equal l [ 100 ] in
  quality ~name:"G.list" ~gen:(G.list elt1000) ~test:ts ~is_minimal:ms;
  quality ~name:"list_len" ~gen:(list_len elt1000) ~test:ts ~is_minimal:ms;
  quality ~name:"list_cont" ~gen:(list_cont elt1000) ~test:ts ~is_minimal:ms;
  Stdio.printf "  self_len: hd l = length l (minimal [1]) -- the frontier case\n";
  let tl l = not (match l with [] -> false | h :: _ -> h = List.length l) in
  let ml l = List.equal Int.equal l [ 1 ] in
  let elt50 = G.int_uniform_inclusive 0 50 in
  quality ~name:"G.list" ~gen:(G.list elt50) ~test:tl ~is_minimal:ml;
  quality ~name:"list_len" ~gen:(list_len elt50) ~test:tl ~is_minimal:ml;
  quality ~name:"list_cont" ~gen:(list_cont elt50) ~test:tl ~is_minimal:ml

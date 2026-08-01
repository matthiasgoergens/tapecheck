(* Is bound5's low normalisation score a VALUE problem or a SLOT
   problem? The challenge scores one exact permutation. If the shrinker
   reliably reaches the right multiset -- two singletons {-1, -32768}
   and three empties -- and only varies in which of the five slots they
   land in, then the residue is positional canonicalisation, which needs
   a span-aware reorder pass rather than any generator encoding. *)
open Base
module G = Base_quickcheck.Generator

let wrap16 x = ((x + 32768) land 0xFFFF) - 32768

let bounded_list =
  G.filter
    (G.union
       [ G.return []
       ; G.map (G.int_inclusive (-32768) 32767) ~f:(fun x -> [ x ])
       ])
    ~f:(fun l -> List.sum (module Int) l ~f:Fn.id < 256)

let gen =
  G.map
    (G.both (G.both bounded_list bounded_list)
       (G.both bounded_list (G.both bounded_list bounded_list)))
    ~f:(fun ((a, b), (c, (d, e))) -> [ a; b; c; d; e ])

let test ls =
  let total =
    List.fold ls ~init:0 ~f:(fun acc l ->
      List.fold l ~init:acc ~f:(fun acc x -> wrap16 (acc + x)))
  in
  total < 5 * 256

let () =
  let exact = ref 0 and right_multiset = ref 0 and n = ref 0 in
  let sizes = Hashtbl.create (module Int) in
  let runs =
    match Stdlib.Sys.getenv_opt "TAPECHECK_RUNS" with
    | Some s -> (try Int.of_string s with _ -> 100)
    | None -> 100
  in
  for t = 0 to runs - 1 do
    match
      Tape_engine.run gen ~test ~seed:((t * 2_654_435_761) land 0x3FFF_FFFF) ~count:200_000 ~size:10
        ~budget:20_000
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; _ } ->
      Int.incr n;
      let flat = List.concat minimal in
      let nonempty = List.length (List.filter minimal ~f:(fun l -> not (List.is_empty l))) in
      Hashtbl.update sizes (List.length flat) ~f:(function None -> 1 | Some c -> c + 1);
      let sorted = List.sort flat ~compare:Int.compare in
      if List.equal Int.equal sorted [ -32768; -1 ] && nonempty = 2 then
        Int.incr right_multiset;
      let rendered =
        "(" ^ String.concat ~sep:", "
          (List.map minimal ~f:(fun l ->
             "[" ^ String.concat ~sep:"; " (List.map l ~f:Int.to_string) ^ "]"))
        ^ ")"
      in
      if String.equal rendered "([], [], [], [-1], [-32768])" then Int.incr exact
  done;
  Stdio.printf "bound5 over %d found runs:\n" !n;
  Stdio.printf "  exact expected permutation : %d\n" !exact;
  Stdio.printf "  RIGHT MULTISET {-1,-32768} : %d   <- slot-order-insensitive\n"
    !right_multiset;
  Stdio.printf "  total element count histogram:\n";
  Hashtbl.to_alist sizes
  |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
  |> List.iter ~f:(fun (k, c) -> Stdio.printf "    %d elements: %d runs\n" k c)

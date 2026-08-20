(* Does the sort_siblings pass actually fire on bound5? A pass that
   proposes nothing and a pass that proposes and is rejected are
   different failures with different fixes, and the challenge score
   cannot tell them apart. *)
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

let describe (c : Tape.choice) =
  match c with
  | Tape.Integer { value; lo; hi } -> Printf.sprintf "I%Ld[%Ld,%Ld]" value lo hi
  | Tape.Float { value; _ } -> Printf.sprintf "F%.2f" value
  | Tape.Bool b -> if b then "T" else "F"
  | Tape.Marker -> "M"

let () =
  let total_sortsib = ref 0 and n = ref 0 in
  for t = 0 to 19 do
    let st = Tape_engine.no_stats () in
    match
      Tape_engine.run gen ~test ~seed:((t * 2_654_435_761) land 0x3FFF_FFFF)
        ~count:200_000 ~size:10 ~budget:20_000 ~stats:st
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { image; _ } ->
      Int.incr n;
      let costs = Tape_engine.Diagnostics.last_pass_costs () in
      let c =
        List.find_map costs ~f:(fun (name, c) ->
          if String.equal name "sort_siblings" then Some c else None)
        |> Option.value ~default:(-1)
      in
      total_sortsib := !total_sortsib + c;
      if t < 2 then begin
        Stdio.printf "seed %d pass costs: %s\n" t
          (String.concat ~sep:", "
             (List.map costs ~f:(fun (nm, c) -> Printf.sprintf "%s=%d" nm c)));
        Stdio.printf "  final tape (%d choices): %s\n"
          (Array.length image.Tape.main)
          (String.concat ~sep:" "
             (Array.to_list (Array.map image.Tape.main ~f:describe)))
      end
  done;
  Stdio.printf "\nsort_siblings attempts over %d runs: %d total, %d mean\n" !n
    !total_sortsib (!total_sortsib / Int.max 1 !n)

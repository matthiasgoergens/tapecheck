(* lengthlist is 64/100 and CHALLENGE.md calls it "genuinely ours".
   Before claiming a cause, measure: are the misses lists that never got
   shorter, and if so is the length prefix the thing that is stuck? *)
open Base
module G = Base_quickcheck.Generator

let gen =
  G.bind (G.int_uniform_inclusive 1 100) ~f:(fun n ->
    G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:n)

let test l =
  match List.max_elt l ~compare:Int.compare with None -> true | Some m -> m < 900

let describe (c : Tape.choice) =
  match c with
  | Tape.Integer { value; lo; hi } -> Printf.sprintf "%Ld[%Ld,%Ld]" value lo hi
  | Tape.Float { value; _ } -> Printf.sprintf "f%.2f" value
  | Tape.Bool b -> if b then "T" else "F"
  | Tape.Marker -> "M"

let () =
  let by_len = Hashtbl.create (module Int) in
  let stuck = ref [] in
  for t = 0 to 99 do
    match Tape_engine.run gen ~test ~seed:(t * 7919) ~count:1_000_000 ~size:30
            ~budget:20_000
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; image; converged; attempts; _ } ->
      let n = List.length minimal in
      Hashtbl.update by_len n ~f:(function None -> 1 | Some c -> c + 1);
      if n > 1 && List.length !stuck < 3 then
        stuck := (t, minimal, image, converged, attempts) :: !stuck
  done;
  Stdio.printf "minimal length histogram over 100 runs:\n";
  Hashtbl.to_alist by_len
  |> List.sort ~compare:(fun (a, _) (b, _) -> Int.compare a b)
  |> List.iter ~f:(fun (n, c) -> Stdio.printf "  length %-3d : %d runs\n" n c);
  Stdio.printf "\nexamples that did not reach length 1:\n";
  List.iter (List.rev !stuck) ~f:(fun (t, m, img, conv, att) ->
    Stdio.printf "  seed %d: %d elements, converged=%b, attempts=%d\n" t
      (List.length m) conv att;
    Stdio.printf "    value: [%s]\n"
      (String.concat ~sep:"; " (List.map m ~f:Int.to_string));
    Stdio.printf "    tape:  %s\n"
      (String.concat ~sep:" " (Array.to_list (Array.map img.Tape.main ~f:describe))))

(* The controlled table shows the stock shrinker spending 0 test calls
   on several rows. Is base_quickcheck's Shrinker.int genuinely empty on
   the edge-biased originals the tape engine finds, or did the harness
   change break the stock arm? *)
open Base
module G = Base_quickcheck.Generator
module S = Base_quickcheck.Shrinker

let show_seq name s v =
  let cands = Sequence.to_list (Sequence.take (S.shrink s v) 8) in
  Stdio.printf "  %-28s %-12s -> %d candidate(s): [%s]\n" name
    (Int.to_string v) (List.length cands)
    (String.concat ~sep:"; " (List.map cands ~f:Int.to_string))

let () =
  Stdio.printf "Shrinker.int candidates:\n";
  List.iter [ 1_000_000; 999_999; 123_458; 100; 7; 1 ] ~f:(fun v ->
    show_seq "S.int" S.int v);
  Stdio.printf "\nWhat originals does the tape engine actually hand over?\n";
  let seen = Hashtbl.create (module Int) in
  for t = 0 to 19 do
    match
      Tape_engine.run (G.int_uniform_inclusive 0 1_000_000)
        ~test:(fun v -> v < 123_457) ~seed:(t * 1_000_003) ~count:200 ~size:10
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { original; _ } ->
      Hashtbl.update seen original ~f:(function None -> 1 | Some c -> c + 1)
  done;
  Hashtbl.to_alist seen
  |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
  |> List.iter ~f:(fun (v, c) -> Stdio.printf "  %3d x  %d\n" c v)

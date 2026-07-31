(* Where do tapecheck's 641 shrink calls go on "int list, length >= 3",
   when Hypothesis finishes the same property in 27?
   See ../tapecheck-hypothesis-baseline/README.md for the comparison. *)

open Base
module G = Base_quickcheck.Generator

let trials = 100

let row ~name ~gen ~test =
  let totals = Hashtbl.Poly.create () in
  let dups = ref 0 and distinct = ref 0 and runs = ref 0 in
  for t = 0 to trials - 1 do
    match Tape_engine.run gen ~test ~seed:(t * 1_000_003) ~count:200 ~size:10 with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed _ ->
      Int.incr runs;
      List.iter (Tape_engine.last_pass_costs ()) ~f:(fun (p, c) ->
        Hashtbl.update totals p ~f:(function None -> c | Some x -> x + c));
      let d, dd = Tape_engine.last_duplicate_stats () in
      dups := !dups + d;
      distinct := !distinct + dd
  done;
  Stdio.printf "%s (%d failing runs)\n" name !runs;
  let n = Int.max 1 !runs in
  Hashtbl.to_alist totals
  |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
  |> List.iter ~f:(fun (p, c) ->
    Stdio.printf "  %-20s %6d avg attempts\n" p (c / n));
  Stdio.printf "  %-20s %6d avg (%.0f%% of proposals were exact repeats)\n"
    "duplicates" (!dups / n)
    (100. *. Float.of_int !dups /. Float.of_int (Int.max 1 (!dups + !distinct)));
  Stdio.printf "\n"

let () =
  row ~name:"int list, fail iff length >= 3"
    ~gen:(G.list (G.int_uniform_inclusive 0 100))
    ~test:(fun l -> List.length l < 3);
  row ~name:"int list, fail iff sum >= 100"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100);
  row ~name:"int uniform (control: tapecheck already cheap here)"
    ~gen:(G.int_uniform_inclusive 0 1_000_000)
    ~test:(fun v -> v < 123_457)

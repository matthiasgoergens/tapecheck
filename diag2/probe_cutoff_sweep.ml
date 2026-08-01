(* The per-pass failure cutoff is a 4.4x cost win on one guarded
   property and a quality LOSS on lengthlist. Both are real, so the
   constant 20 is tuned to the benchmarks it was tuned on. Sweep it
   across the shapes that disagree before proposing anything. *)
open Base
module G = Base_quickcheck.Generator

let runs = 50

let measure ~gen ~test ~is_minimal ~mpf =
  let found = ref 0 and minimal = ref 0 and calls = ref 0 in
  for t = 0 to runs - 1 do
    match
      Tape_engine.run gen ~test ~seed:(t * 7919) ~count:1_000_000 ~size:30
        ~budget:200_000 ~max_pass_failures:mpf
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; attempts; _ } ->
      Int.incr found;
      calls := !calls + attempts;
      if is_minimal m then Int.incr minimal
  done;
  (!minimal, !calls / runs)

let props =
  [ ( "A len>=3 (guard: cutoff win)"
    , (fun mpf ->
        measure ~mpf
          ~gen:(G.list (G.int_uniform_inclusive 0 100))
          ~test:(fun l -> List.length l < 3)
          ~is_minimal:(fun l -> List.equal Int.equal l [ 0; 0; 0 ])) )
  ; ( "B deep bind, sum>=500 (guard)"
    , (fun mpf ->
        measure ~mpf
          ~gen:
            (G.bind (G.int_uniform_inclusive 1 200) ~f:(fun len ->
               G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len))
          ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 500)
          ~is_minimal:(fun l -> List.equal Int.equal l [ 500 ])) )
  ; ( "C lengthlist, max>=900 (challenge)"
    , (fun mpf ->
        measure ~mpf
          ~gen:
            (G.bind (G.int_uniform_inclusive 1 100) ~f:(fun n ->
               G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:n))
          ~test:(fun l ->
            match List.max_elt l ~compare:Int.compare with
            | None -> true
            | Some m -> m < 900)
          ~is_minimal:(fun l -> List.equal Int.equal l [ 900 ])) )
  ; ( "D zig-zag |m-n|<>1 (guard)"
    , (fun mpf ->
        measure ~mpf
          ~gen:
            (G.both (G.int_uniform_inclusive 0 300) (G.int_uniform_inclusive 0 300))
          ~test:(fun (m, n) -> abs (m - n) <> 1)
          ~is_minimal:(fun (m, n) -> (m = 0 && n = 1) || (m = 1 && n = 0))) )
  ]

let () =
  let settings =
    [ ("20", Some 20); ("25", Some 25); ("30", Some 30); ("35", Some 35)
    ; ("40", Some 40); ("50", Some 50) ]
  in
  Stdio.printf "%-36s" "cutoff";
  List.iter settings ~f:(fun (l, _) -> Stdio.printf " %14s" l);
  Stdio.printf "\n";
  List.iter props ~f:(fun (name, f) ->
    Stdio.printf "%-36s" name;
    List.iter settings ~f:(fun (_, mpf) ->
      let m, c = f mpf in
      Stdio.printf " %6d/%d %5d" m runs c);
    Stdio.printf "\n");
  Stdio.printf "\n  cells are  minimal/%d  mean-calls\n" runs

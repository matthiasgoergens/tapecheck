(* Does the per-pass cutoff cost quality on a property whose passes need
   a long dry spell before their first success?

   The seven benchmark properties all succeed well inside 20 consecutive
   failures, so they cannot answer this and the adaptive growth ported
   from Hypothesis (shrinker.py:969-971) is untested by them. Ground
   truth is [max_pass_failures = None] -- no cutoff, full search. If the
   cutoff matches it, the cutoff is safe here; if not, the gap is what
   the adaptation has to close. *)
open Base
module G = Base_quickcheck.Generator

let trials = 100

let run ~name ~gen ~test ~is_minimal ~cutoff =
  let found = ref 0 and minimal = ref 0 and calls = ref 0 in
  for t = 0 to trials - 1 do
    match
      Tape_engine.run gen ~test ~seed:(t * 1_000_003) ~count:200 ~size:10
        ~max_pass_failures:cutoff
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; attempts; _ } ->
      Int.incr found;
      calls := !calls + attempts;
      if is_minimal m then Int.incr minimal
  done;
  Stdio.printf "  %-22s found %3d, minimal %3d, %6d calls\n" name !found
    !minimal (!calls / trials)

let compare ~name ~gen ~test ~is_minimal =
  Stdio.printf "%s\n" name;
  run ~name:"no cutoff (truth)" ~gen ~test ~is_minimal ~cutoff:None;
  run ~name:"cutoff 20 adaptive" ~gen ~test ~is_minimal ~cutoff:(Some 20);
  run ~name:"cutoff 3 adaptive" ~gen ~test ~is_minimal ~cutoff:(Some 3);
  Stdio.printf "\n"

let () =
  compare ~name:"long list: fails iff length >= 25"
    ~gen:(G.list (G.int_uniform_inclusive 0 100))
    ~test:(fun l -> List.length l < 25)
    ~is_minimal:(fun l ->
      List.length l = 25 && List.for_all l ~f:(fun x -> x = 0));
  compare ~name:"long list: fails iff sum >= 1000"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 1000)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 1000 ]);
  compare ~name:"deep bind: len in [1,200], sum >= 500"
    ~gen:
      (let open G.Let_syntax in
       let%bind len = G.int_uniform_inclusive 1 200 in
       G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 500)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 500 ])

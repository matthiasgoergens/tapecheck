(* All lengthlist misses stop at exactly 581 attempts with
   converged=false and 20000 budget unspent. Which limit is it? *)
open Base
module G = Base_quickcheck.Generator

let gen =
  G.bind (G.int_uniform_inclusive 1 100) ~f:(fun n ->
    G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:n)

let test l =
  match List.max_elt l ~compare:Int.compare with None -> true | Some m -> m < 900

let trial ~label ?max_shrinks ?max_stall ?max_pass_failures () =
  let hits = ref 0 and total_att = ref 0 and conv = ref 0 in
  for t = 0 to 49 do
    match
      Tape_engine.run gen ~test ~seed:(t * 7919) ~count:1_000_000 ~size:30
        ~budget:200_000 ?max_shrinks ?max_stall ?max_pass_failures
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; attempts; converged; _ } ->
      total_att := !total_att + attempts;
      if converged then Int.incr conv;
      if List.length minimal = 1 then Int.incr hits
  done;
  Stdio.printf "  %-42s  %2d/50 minimal, %2d converged, mean %d attempts\n" label
    !hits !conv (!total_att / 50)

let () =
  Stdio.printf "lengthlist, varying one limit at a time:\n";
  trial ~label:"defaults" ();
  trial ~label:"max_pass_failures = None" ~max_pass_failures:None ();
  trial ~label:"max_shrinks = 20000" ~max_shrinks:20_000 ();
  trial ~label:"max_stall = 100000" ~max_stall:(Some 100_000) ();
  trial ~label:"all three lifted" ~max_pass_failures:None ~max_shrinks:20_000
    ~max_stall:(Some 100_000) ()

(* Would splitting at structural boundaries give the tape span structure?

   base_quickcheck splits exactly once (generator.ml:87, inside [fn]), so
   lists put every choice in [main] with zero streams and there is no
   structure to infer. But that is a property of the CURRENT combinators,
   not of the approach: tapecheck's key is a [key_elt list], i.e. already
   a path, so nested splits would give a nested tree of streams --
   exactly the shape Hypothesis's [examples] provide.

   This writes a list generator that splits per element and compares it
   against the stock one on the frontier property [hd l = length l],
   which needs a structural move no local lowering reaches. *)
open Base
module G = Base_quickcheck.Generator

(* One split per element, so each element's draws land on their own
   stream keyed by its position in the split path. *)
let list_split elt =
  G.create (fun ~size ~random ->
    let len = Splittable_random.int random ~lo:0 ~hi:(Int.max 1 size) in
    List.init len ~f:(fun _ ->
      let r = Splittable_random.split random in
      G.generate elt ~size ~random:r))

let count img =
  ( Array.length img.Tape.main
  , Array.length img.Tape.streams
  , Array.fold img.Tape.streams ~init:0 ~f:(fun a (_, c) -> a + Array.length c) )

let compare_shape ~name ~gen =
  match
    Tape_engine.run gen ~test:(fun _ -> false) ~seed:99 ~count:1 ~size:10
      ~budget:0
  with
  | Tape_engine.Passed _ -> Stdio.printf "  %s: no failure\n" name
  | Tape_engine.Failed { image; original; _ } ->
    let m, ns, nc = count image in
    Stdio.printf "  %-12s %2d elements -> main %2d choices, %d streams, %d stream choices\n"
      name (List.length original) m ns nc

let quality ~name ~gen =
  let found = ref 0 and minimal = ref 0 and calls = ref 0 in
  for t = 0 to 99 do
    match
      Tape_engine.run gen
        ~test:(fun l ->
          not (match l with [] -> false | h :: _ -> h = List.length l))
        ~seed:(t * 1_000_003) ~count:200 ~size:10
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; attempts; _ } ->
      Int.incr found;
      calls := !calls + attempts;
      if List.equal Int.equal m [ 1 ] then Int.incr minimal
  done;
  Stdio.printf "  %-12s found %3d, fully minimal %3d, %4d calls\n" name !found
    !minimal (!calls / 100)

let () =
  let elt = G.int_uniform_inclusive 0 50 in
  Stdio.printf "tape shape (one sample, no shrinking):\n";
  compare_shape ~name:"stock list" ~gen:(G.list elt);
  compare_shape ~name:"split list" ~gen:(list_split elt);
  Stdio.printf "\nself_len shrink quality (100 seeds):\n";
  quality ~name:"stock list" ~gen:(G.list elt);
  quality ~name:"split list" ~gen:(list_split elt)

(* Does the determinism check actually fire, and does it stay quiet on
   honest generators?

   Both halves matter. A check that never fires is decoration; a check
   that fires on ordinary generators is worse than none. *)
open Base
module G = Base_quickcheck.Generator

(* An honest generator: a pure function of the tape. *)
let honest = G.list (G.int_uniform_inclusive 0 1000)

(* A dishonest one: reads a mutable global, so replaying the same tape
   twice draws differently. This is the clock-reading generator in its
   smallest form. *)
let counter = ref 0

let dishonest =
  G.create (fun ~size:_ ~random ->
    Int.incr counter;
    (* The tape sees one draw, but the VALUE also depends on the counter,
       and the number of draws depends on it too. *)
    let n = Splittable_random.int random ~lo:0 ~hi:3 in
    List.init (n + (!counter % 2)) ~f:(fun _ ->
      Splittable_random.int random ~lo:0 ~hi:1000))

let first_failure gen test =
  let rec go t =
    if t > 60 then None
    else
      match Tape_engine.run gen ~test ~seed:(t * 7919) ~count:50 ~size:10 with
      | Tape_engine.Failed { image; _ } -> Some image
      | Tape_engine.Passed _ -> go (t + 1)
  in
  go 0

let () =
  let test _ = false in
  let honest_ok =
    match first_failure honest test with
    | None -> false
    | Some img ->
      Tape_engine.check_generator_determinism ~gen:honest ~size:10 ~test img
  in
  counter := 0;
  let dishonest_flagged =
    match first_failure dishonest test with
    | None -> false
    | Some img ->
      not
        (Tape_engine.check_generator_determinism ~gen:dishonest ~size:10 ~test
           img)
  in
  Stdio.printf "honest generator passes the check:      %b\n" honest_ok;
  Stdio.printf "dishonest generator is flagged:         %b\n" dishonest_flagged;
  if not honest_ok then
    Stdio.printf "  FAIL: false positive on an honest generator\n";
  if not dishonest_flagged then
    Stdio.printf "  FAIL: non-determinism went undetected\n";
  if not (honest_ok && dishonest_flagged) then Stdlib.exit 1;
  Stdio.printf "\n%s\n" Tape_engine.nondeterminism_warning

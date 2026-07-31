(* How well does the two-replay determinism check do on a generator that
   is only OCCASIONALLY non-deterministic?

   The check replays one image twice and compares. That catches an
   always-divergent generator every time. A generator that diverges with
   probability p should be caught with probability roughly 2p(1-p) + ...
   -- i.e. only when the two replays happen to land on different
   behaviours. Measured here rather than reasoned about, across a range
   of p. *)
open Base
module G = Base_quickcheck.Generator

let flake_rate = ref 0.0
let rng = ref (Random.State.make [| 42 |])

(* Diverges with probability [!flake_rate] on any given generation. *)
let flaky =
  G.create (fun ~size:_ ~random ->
    let extra =
      if Float.( < ) (Random.State.float !rng 1.0) !flake_rate then 1 else 0
    in
    let n = Splittable_random.int random ~lo:0 ~hi:3 in
    List.init (n + extra) ~f:(fun _ ->
      Splittable_random.int random ~lo:0 ~hi:1000))

let first_failure () =
  let rec go t =
    if t > 60 then None
    else
      match
        Tape_engine.run flaky ~test:(fun _ -> false) ~seed:(t * 7919) ~count:50
          ~size:10
      with
      | Tape_engine.Failed { image; _ } -> Some image
      | Tape_engine.Passed _ -> go (t + 1)
  in
  go 0

let () =
  Stdio.printf "detection rate of the two-replay check, 400 trials each\n\n";
  Stdio.printf "  %-14s %-12s\n" "flake rate" "detected";
  List.iter [ 1.0; 0.5; 0.25; 0.1; 0.05; 0.01 ] ~f:(fun p ->
    flake_rate := p;
    rng := Random.State.make [| 42 |];
    let detected = ref 0 and n = ref 0 in
    for _ = 0 to 399 do
      match first_failure () with
      | None -> ()
      | Some img ->
        Int.incr n;
        if
          not
            (Tape_engine.check_generator_determinism ~gen:flaky ~size:10
               ~test:(fun _ -> false)
               img)
        then Int.incr detected
    done;
    Stdio.printf "  %-14.2f %d/%d (%.0f%%)\n" p !detected !n
      (100. *. Float.of_int !detected /. Float.of_int (Int.max 1 !n)))

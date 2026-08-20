(* Deliberately WEAK laws: round-trips, idempotence, order axioms,
   invariance under a knob that should not matter. Almost any function
   satisfies them, so they say little about whether the shrinker is
   good -- and they are exactly the ones that catch seam bugs, because
   a seam that has been rewired wrongly usually stops being a bijection,
   or stops being idempotent, or starts depending on something it
   should not.

   Stated over tapes produced by real generators rather than hand-built
   ones, so the inputs have the shapes the engine actually meets. *)
open! Base
module G = Base_quickcheck.Generator

let failures = ref 0
let checked = ref 0

let law name cond detail =
  Int.incr checked;
  if not cond then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-48s %s\n" name detail
  end
  else Stdio.printf "  ok   %-48s %s\n" name detail

let subject =
  G.both
    (G.list (G.int_inclusive (-1000) 1000))
    (G.both (G.list G.string) (G.option (G.float_inclusive (-1e6) 1e6)))

(* One recorded image per seed, from a real generator. *)
let images n =
  List.init n ~f:(fun seed ->
    let tape = Tape.create () in
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
    in
    let (_ : _) = G.generate subject ~size:14 ~random in
    (Tape.finish tape).Tape.image)

let trivialize (img : Tape.image) : Tape.image =
  { main = Array.map img.Tape.main ~f:Tape.Domain.target
  ; streams =
      Array.map img.Tape.streams ~f:(fun (k, a) ->
        (k, Array.map a ~f:Tape.Domain.target))
  }

let () =
  Stdio.printf "cheap laws\n\n";
  let imgs = images 300 in

  (* Round-trip: serialisation is a bijection on the images we produce.
     A regression file and a resumable shrink both depend on it. *)
  let bad_roundtrip =
    List.count imgs ~f:(fun img ->
      match Tape.deserialize_image (Tape.serialize_image img) with
      | Some back -> Tape.compare_image back img <> 0
      | None -> true)
  in
  law "deserialize (serialize img) = img" (bad_roundtrip = 0)
    (Printf.sprintf "%d/%d failed" bad_roundtrip (List.length imgs));

  (* Idempotence: driving every choice to its target is a projection. *)
  let bad_triv =
    List.count imgs ~f:(fun img ->
      Tape.compare_image (trivialize (trivialize img)) (trivialize img) <> 0)
  in
  law "trivialize is idempotent" (bad_triv = 0)
    (Printf.sprintf "%d/%d failed" bad_triv (List.length imgs));

  (* Idempotence of decode-then-encode: replaying a recorded image must
     re-record that same image. If this ever breaks, every accepted
     shrink is built on sand. *)
  let bad_replay =
    List.count (List.init 300 ~f:Fn.id) ~f:(fun seed ->
      let t1 = Tape.create () in
      Tape.start_recording t1;
      let r1 =
        Splittable_random.For_tape.attach (Splittable_random.of_int seed) t1
      in
      let (_ : _) = G.generate subject ~size:14 ~random:r1 in
      let img = (Tape.finish t1).Tape.image in
      let t2 = Tape.create () in
      Tape.start_replay_image t2 img;
      let r2 =
        Splittable_random.For_tape.attach (Splittable_random.of_int 12345) t2
      in
      let (_ : _) = G.generate subject ~size:14 ~random:r2 in
      let out = (Tape.finish t2).Tape.image in
      Tape.compare_image out img <> 0)
  in
  law "replay re-records the same image" (bad_replay = 0)
    (Printf.sprintf "%d/300 failed" bad_replay);

  (* Order axioms for the shrink order. Antisymmetry and transitivity
     are what let every pass say "strictly smaller" and mean it. *)
  let arrs = List.map imgs ~f:(fun i -> i.Tape.main) in
  let pairs =
    List.concat_map arrs ~f:(fun a -> List.map arrs ~f:(fun b -> (a, b)))
  in
  let bad_anti =
    List.count pairs ~f:(fun (a, b) ->
      let x = Tape.compare_shortlex a b and y = Tape.compare_shortlex b a in
      not ((x = 0 && y = 0) || (x > 0 && y < 0) || (x < 0 && y > 0)))
  in
  law "compare_shortlex is antisymmetric" (bad_anti = 0)
    (Printf.sprintf "%d/%d pairs" bad_anti (List.length pairs));
  let bad_refl =
    List.count arrs ~f:(fun a -> Tape.compare_shortlex a a <> 0)
  in
  law "compare_shortlex is reflexive" (bad_refl = 0)
    (Printf.sprintf "%d failed" bad_refl);
  let sample = List.take arrs 40 in
  let bad_trans =
    List.count
      (List.concat_map sample ~f:(fun a ->
         List.concat_map sample ~f:(fun b ->
           List.map sample ~f:(fun c -> (a, b, c)))))
      ~f:(fun (a, b, c) ->
        Tape.compare_shortlex a b <= 0
        && Tape.compare_shortlex b c <= 0
        && Tape.compare_shortlex a c > 0)
  in
  law "compare_shortlex is transitive" (bad_trans = 0)
    (Printf.sprintf "%d triples" bad_trans);

  (* Equal images compare equal, and equality agrees with the order. *)
  let bad_eq =
    List.count imgs ~f:(fun img ->
      not (Tape.equal_choices img.Tape.main img.Tape.main))
  in
  law "equal_choices is reflexive" (bad_eq = 0)
    (Printf.sprintf "%d failed" bad_eq);

  (* Invariance under a knob that must not matter: the number of worker
     domains. The engine promises accepted-edit sequences are identical
     at every ?domains, so the reported minimal must be too. *)
  let prop l = List.length l < 4 in
  let gen_l = G.list (G.int_inclusive 0 200) in
  let both_failed = ref 0 in
  let disagreements =
    List.count (List.init 40 ~f:Fn.id) ~f:(fun seed ->
      let one =
        Tape_engine.run ~seed ~count:300 ~domains:1 gen_l ~test:prop
      in
      let four =
        Tape_engine.run ~seed ~count:300 ~domains:4 gen_l ~test:prop
      in
      match (one, four) with
      | Tape_engine.Failed a, Tape_engine.Failed b ->
        Int.incr both_failed;
        not (List.equal Int.equal a.Tape_engine.minimal b.Tape_engine.minimal)
      | Tape_engine.Passed _, Tape_engine.Passed _ -> false
      | _ -> true)
  in
  law "minimal does not depend on ?domains" (disagreements = 0)
    (Printf.sprintf "%d/40 seeds disagreed" disagreements);
  law "  ^ was not vacuous" (!both_failed > 30)
    (Printf.sprintf "%d/40 seeds failed under both" !both_failed);

  (* Shrinking is a fixpoint: resuming from a converged result must not
     find anything smaller. *)
  let converged_seen = ref 0 in
  let not_fixed =
    List.count (List.init 40 ~f:Fn.id) ~f:(fun seed ->
      match Tape_engine.run ~seed ~count:300 gen_l ~test:prop with
      | Tape_engine.Passed _ -> false
      | Tape_engine.Failed { image; converged; _ } ->
        if converged then Int.incr converged_seen;
        converged
        &&
        (match Tape_engine.resume gen_l ~test:prop image with
         | Tape_engine.Passed _ -> true
         | Tape_engine.Failed second ->
           Tape.compare_image second.Tape_engine.image image < 0))
  in
  law "a converged shrink is a fixpoint under resume" (not_fixed = 0)
    (Printf.sprintf "%d/40 seeds shrank further" not_fixed);
  law "  ^ was not vacuous" (!converged_seen > 30)
    (Printf.sprintf "%d/40 seeds converged" !converged_seen);

  Stdio.printf "\n  %d laws checked\n" !checked;
  if !failures > 0 then begin
    Stdio.printf "\ntest_cheap_laws: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_cheap_laws: all laws held\n"

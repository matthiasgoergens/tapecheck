(* The shrink order's own laws, property-tested with tapecheck itself.

   [s_accept] in the engine is exactly

     fun ~best image _value -> Tape.compare_image image best < 0

   and nothing else. That single comparison is the entire definition of
   what shrinking means here, and before this file it had no property
   test at all -- the only uses of [compare_image] in the suite were
   round-trip checks asserting [= 0]. A property-testing library that
   does not property-test its own order is running an oracle it has
   never checked.

   The laws below are the ones the engine actually relies on. Where a
   law does NOT hold, that is stated and tested as such rather than
   quietly omitted, because an untested exception is how a preorder gets
   mistaken for an order later. *)
open! Base

module G = Base_quickcheck.Generator

let failures = ref 0

let report name ok detail =
  if not ok then Int.incr failures;
  Stdio.printf "  %s %-50s %s\n" (if ok then "ok  " else "FAIL") name detail

(* Bounds are drawn from a small pool, and crossed bounds (lo > hi) are
   included deliberately: a hand-edited tape can carry them, resume must
   survive them (tapecheck#11), and the clamps are total precisely so
   that they are ordinary data rather than a crash. An order that is
   only lawful on well-formed input is not much of an order. *)
let choice_gen =
  let i64 = G.map (G.int_uniform_inclusive (-4) 4) ~f:Int64.of_int in
  let flt = G.of_list [ -2.; -1.; -0.; 0.; 1.; 2.; Float.nan ] in
  G.union
    [ G.map
        (G.both i64 (G.both i64 i64))
        ~f:(fun (value, (lo, hi)) -> Tape.Integer { value; lo; hi })
    ; G.map
        (G.both flt (G.both flt flt))
        ~f:(fun (value, (lo, hi)) -> Tape.Float { value; lo; hi })
    ; G.map G.bool ~f:(fun b -> Tape.Bool b)
    ; G.return Tape.Marker
    ]

let image_gen =
  G.map (G.list choice_gen) ~f:(fun l ->
    Tape.image_of_main (Array.of_list l))

let sign n = if n < 0 then -1 else if n > 0 then 1 else 0

let run_prop name gen test =
  match Tape_engine.run gen ~test ~seed:20260809 ~count:3000 ~size:12 with
  | Tape_engine.Passed _ -> report name true "no counterexample in 3000 cases"
  | Tape_engine.Failed _ -> report name false "COUNTEREXAMPLE (see minimal below)"

let () =
  Stdio.printf "shrink-order laws (Tape.Domain and Tape.compare_image)\n\n";

  (* --- the order itself ------------------------------------------- *)
  run_prop "compare_choice is reflexive" choice_gen (fun c ->
    Tape.Domain.compare c c = 0);

  run_prop "compare_choice is sign-symmetric" (G.both choice_gen choice_gen)
    (fun (a, b) -> sign (Tape.Domain.compare a b) = -sign (Tape.Domain.compare b a));

  run_prop "compare_choice is transitive"
    (G.both choice_gen (G.both choice_gen choice_gen)) (fun (a, (b, c)) ->
      let ( <= ) x y = Tape.Domain.compare x y <= 0 in
      if a <= b && b <= c then a <= c else true);

  (* --- target agrees with the order ------------------------------- *)
  run_prop "target is a lower bound" choice_gen (fun c ->
    Tape.Domain.compare (Tape.Domain.target c) c <= 0);

  run_prop "at_target agrees with compare-to-target" choice_gen (fun c ->
    Bool.equal (Tape.Domain.at_target c)
      (Tape.Domain.compare c (Tape.Domain.target c) = 0));

  (* Stated with [compare], not [Poly.equal], and the difference is not
     pedantic: the first version of this law FAILED, and the
     counterexample was Float { lo = nan; hi = 1. }. [target] is
     genuinely idempotent there -- compare returns 0 -- but the two
     results carry a NaN bound, and structural equality on NaN is false.
     The law was wrong, not the code. Recorded because "my test found a
     bug" was the wrong first conclusion and the probe took a minute. *)
  run_prop "target is idempotent (under compare)" choice_gen (fun c ->
    Tape.Domain.compare (Tape.Domain.target (Tape.Domain.target c))
      (Tape.Domain.target c)
    = 0);

  (* And the structural version, restricted to choices whose bounds are
     not NaN, so the stronger property is still covered where it holds. *)
  run_prop "target is structurally idempotent (non-NaN bounds)" choice_gen
    (fun c ->
      let nan_bounds =
        match c with
        | Tape.Float { lo; hi; _ } -> Float.is_nan lo || Float.is_nan hi
        | _ -> false
      in
      if nan_bounds then true
      else
        Poly.equal
          (Tape.Domain.target (Tape.Domain.target c))
          (Tape.Domain.target c));

  run_prop "target is itself at target" choice_gen (fun c ->
    Tape.Domain.at_target (Tape.Domain.target c));

  (* THE LAW THAT MAKES THE REST MEAN ANYTHING.

     Everything above relates a choice only to ITSELF, so all of it is
     satisfied by [target c = c] with [at_target _ = true] -- an engine
     that shrinks nothing passes every law stated so far. Codex made
     that point against the first version of this file and it was right.

     This one is cross-value: the target of a choice must be no larger
     than ANY other choice over the same domain. It fails immediately
     for the identity mutant, with c = 2 and d = 0 over [0,2]. *)
  run_prop "target of a domain is <= every value in it"
    (G.both choice_gen choice_gen) (fun (c, d) ->
      let same_domain =
        match (c, d) with
        | Tape.Integer a, Tape.Integer b ->
          Int64.equal a.lo b.lo && Int64.equal a.hi b.hi
        | Tape.Float a, Tape.Float b ->
          (* bit equality, so NaN bounds count as the same domain *)
          let bits = Int64.bits_of_float in
          Int64.equal (bits a.lo) (bits b.lo) && Int64.equal (bits a.hi) (bits b.hi)
        | Tape.Bool _, Tape.Bool _ | Tape.Marker, Tape.Marker -> true
        | _ -> false
      in
      if not same_domain then true
      else Tape.Domain.compare (Tape.Domain.target c) d <= 0);

  (* Strict progress: a choice NOT at its target must be strictly larger
     than the target. Without this, [compare] could rank everything
     equal and the descent would have nothing to descend. *)
  run_prop "a non-target choice is strictly above its target" choice_gen
    (fun c ->
      if Tape.Domain.at_target c then true
      else Tape.Domain.compare (Tape.Domain.target c) c < 0);

  (* And the identity-vs-order distinction, as a law rather than a
     one-off: equal structure implies equal rank, but NOT conversely. *)
  run_prop "structural equality implies compare = 0"
    (G.both choice_gen choice_gen) (fun (a, b) ->
      if Tape.Domain.equal a b then Tape.Domain.compare a b = 0 else true);

  (* --- the image order the engine actually accepts on -------------- *)
  run_prop "compare_image is reflexive" image_gen (fun i ->
    Tape.compare_image i i = 0);

  run_prop "compare_image is sign-symmetric" (G.both image_gen image_gen)
    (fun (a, b) -> sign (Tape.compare_image a b) = -sign (Tape.compare_image b a));

  run_prop "compare_image is transitive"
    (G.both image_gen (G.both image_gen image_gen)) (fun (a, (b, c)) ->
      let ( <= ) x y = Tape.compare_image x y <= 0 in
      if a <= b && b <= c then a <= c else true);

  run_prop "shorter image is always smaller" (G.both image_gen image_gen)
    (fun (a, b) ->
      let la = Array.length a.Tape.main and lb = Array.length b.Tape.main in
      if la < lb then Tape.compare_image a b < 0 else true);

  (* --- the law the engine's termination rests on ------------------- *)
  run_prop "trivializing an image never increases it" image_gen (fun i ->
    let t =
      Tape.image_of_main (Array.map i.Tape.main ~f:Tape.Domain.target)
    in
    Tape.compare_image t i <= 0);

  (* --- and the law that does NOT hold, pinned as such -------------- *)
  (* compare_image = 0 does not imply structural equality: float_key is
     a DISTANCE, so -1.0 and 1.0 about a target of 0.0 compare equal.
     The engine is safe because acceptance is strict (< 0), but the
     comment on compare_image calls it "a total order" and it is a total
     PREORDER. Pinned so the distinction cannot quietly be lost. *)
  let a = Tape.image_of_main [| Tape.Float { value = -1.; lo = -2.; hi = 2. } |] in
  let b = Tape.image_of_main [| Tape.Float { value = 1.; lo = -2.; hi = 2. } |] in
  report "compare_image is a PREORDER, not an order"
    (Tape.compare_image a b = 0 && not (Poly.equal a b))
    "-1.0 and 1.0 compare equal about target 0.0, and are not equal";

  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf "test_domain_laws: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "test_domain_laws: all passed\n"

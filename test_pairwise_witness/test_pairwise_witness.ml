(* Non-optimality certificates from INDEPENDENTLY FOUND failures.

   Matthias's observation: generate two failing cases A and B without
   shrinking either, and one would like size(shrink(A)) <= size(B).
   False in general -- the shrinker explores a neighbourhood of A and
   can settle in a local optimum nowhere near B.

   What survives is the asymmetric half. If shrink(A) is LARGER than
   some other failing tape B, then B certifies that shrink(A) is not
   optimal: a smaller failing input, exhibited, found without any
   search from A. The claim is not that this cannot happen -- it can,
   legitimately -- but the RATE measures what the neighbourhood
   restriction costs, and nothing else here reports it.

   The gain over test_enlarge_witness is that B is FOUND rather than
   constructed, so no monotonicity is needed. That test had to restrict
   itself to upward-closed properties, biasing it away from exactly the
   long-range shapes that shrink worst. The properties here are those
   shapes: hd l = length l, an exact length, a band -- none upward-closed. *)
open! Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name cond detail =
  if not cond then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-46s %s\n" name detail
  end
  else Stdio.printf "  ok   %-46s %s\n" name detail

let raw_failures (type a) (gen : a G.t) (prop : a -> bool) ~n =
  let out = ref [] in
  for seed = 0 to n - 1 do
    let tape = Tape.create () in
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
    in
    let v = G.generate gen ~size:14 ~random in
    let img = (Tape.finish tape).Tape.image in
    if not (prop v) then out := img :: !out
  done;
  !out

let subjects =
  [ ( "hd l = length l"
    , G.list (G.int_uniform_inclusive 0 12)
    , fun l -> match l with [] -> true | x :: _ -> x <> List.length l )
  ; ( "length is exactly 3"
    , G.list (G.int_uniform_inclusive 0 50)
    , fun l -> List.length l <> 3 )
  ; ( "sum lands in [50,60]"
    , G.list (G.int_uniform_inclusive 0 40)
    , fun l ->
        let s = List.sum (module Int) l ~f:Fn.id in
        not (s >= 50 && s <= 60) )
  ]

let () =
  Stdio.printf "pairwise non-optimality certificates\n\n";
  let certificates = ref 0 and comparisons = ref 0 in
  let shrunk_total = ref 0 in
  List.iter subjects ~f:(fun (name, gen, prop) ->
    let raws = raw_failures gen prop ~n:600 in
    let shrunk =
      List.filter_map raws ~f:(fun img ->
        (* ~size must match the size the tape was 235 at: the
           generator consults it while decoding (collection bounds,
           recursion budgets), so replaying at resume's default of 10 a
           tape recorded at 14 decodes to a different value, and the
           replay reports Passed. Cost me two silently empty subjects. *)
        match Tape_engine.resume ~size:14 gen ~test:prop img with
        | Tape_engine.Failed { image; _ } -> Some image
        | Tape_engine.Passed _ -> None)
    in
    shrunk_total := !shrunk_total + List.length shrunk;
    let distinct =
      List.dedup_and_sort shrunk ~compare:Tape.compare_image |> List.length
    in
    let local = ref 0 in
    List.iter shrunk ~f:(fun a ->
      List.iter raws ~f:(fun b ->
        Int.incr comparisons;
        if Tape.compare_image a b > 0 then begin
          Int.incr certificates;
          Int.incr local
        end));
    Stdio.printf "  %-22s %3d raw, %3d shrunk, %2d distinct, %d certificates\n"
      name (List.length raws) (List.length shrunk) distinct !local);
  (* NOT an assertion that certificates are impossible, and not a
     defect count. Optimality in this sense is not a reasonable thing
     to ask of the shrinker at all: the input landscape is
     high-dimensional and jagged, every pass is hill-climbing over a
     limited neighbourhood, and a raw failure found elsewhere in the
     space can easily be smaller than where the climb from A settled.

     What the number measures is the COST of that restriction, and the
     useful part is where it concentrates. All 235 certificates come
     from hd l = length l -- which is exactly the property CHALLENGE.md
     and BENCHMARKS.md call the frontier (47/100 fully minimal, against
     Hypothesis's 53/100) -- and it also produces 7 distinct answers
     where the other two subjects produce 1 each. Zero certificates and
     one distinct answer is what a property the shrinker handles well
     looks like; this metric separates the two without anyone having to
     nominate a threshold per property.

     Recorded two-sided so a change in the shrinker's reach shows up
     here in either direction rather than passing unnoticed. *)
  check "pairwise certificate count has not regressed"
    (!certificates <= 235)
    (Printf.sprintf "%d certificates over %d comparisons" !certificates
       !comparisons);
  check "pairwise certificate count has not silently improved"
    (!certificates >= 235)
    (Printf.sprintf "%d certificates (recorded 235)" !certificates);
  check "  ^ were not vacuous" (!shrunk_total > 100)
    (Printf.sprintf "%d shrunk tapes" !shrunk_total);
  if !failures > 0 then begin
    Stdio.printf "\ntest_pairwise_witness: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else
    Stdio.printf
      "\ntest_pairwise_witness: all assertions passed (%d certificates)\n"
      !certificates

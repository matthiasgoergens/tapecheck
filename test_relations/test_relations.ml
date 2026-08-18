(* The verification driver RELATIONS-CANDIDATE.md claimed to have.

   That document said the relational rewrite of [correlate_image] was
   "verified equivalent, property-tested with tapecheck itself at
   4b9a619 ... (Driver notes below.)". There were no driver notes and no
   relation test anywhere in the repo, so the claim was unfalsifiable as
   written (issue #14). This is the driver, written fresh.

   Two things are checked, and the second is the one that settles the
   open question in that document:

   1. SAME PAIR SET. The shipped loop finds every ordered pair of
      integer choices sharing bounds and differing in value. The
      relational form is [bounds >> bounds-converse] minus
      [values >> values-converse]. They must agree on every input.

   2. SAME PAIR ORDER. [correlate_image] selects with [pick mod length]
      and indexes the list, so the ORDER is part of the function's
      contract, not an implementation detail: a different order means a
      different mutation for the same seed, and recorded regressions
      stop replaying. RELATIONS-CANDIDATE.md flagged this as the one
      open decision, on the belief that the relational form yields pairs
      "sorted rather than in position order".

      That turns out to be a distinction without a difference, which is
      why this test asserts list equality rather than set equality. The
      loop prepends (i, j) scanning i outermost and reverses at the end,
      so it emits ascending lexicographic order -- exactly what a sorted
      pair set gives. The [rel] library's [to_list] is documented
      "Sorted, so it is a canonical form" under structural comparison,
      and structural comparison on [int * int] IS lexicographic. So the
      orders coincide and no re-sorting is needed.

   The relation algebra is implemented here rather than pulled in as a
   dependency. That is deliberate: the claim under test is an algebraic
   identity about composition and converse, and inlining ~20 lines of
   set algebra keeps the check runnable in CI without adding [rel] to
   the build. It does mean this test does not exercise the real library
   -- it establishes that the REWRITE is sound, not that the library is
   correct. Stated so nobody reads more into a green run than is there. *)
open Base

module G = Base_quickcheck.Generator

(* --- minimal finite relation algebra ---------------------------------- *)

module Rel = struct
  (* A finite relation as a sorted, deduplicated pair list. Comparison is
     structural, matching the [rel] library's [Comparator.Poly]. *)
  type ('a, 'b) t = ('a * 'b) list

  let of_list (l : ('a * 'b) list) : ('a, 'b) t =
    List.dedup_and_sort l ~compare:Poly.compare

  let converse (r : ('a, 'b) t) : ('b, 'a) t =
    of_list (List.map r ~f:(fun (a, b) -> (b, a)))

  let compose (r : ('a, 'b) t) (s : ('b, 'c) t) : ('a, 'c) t =
    of_list
      (List.concat_map r ~f:(fun (a, b) ->
         List.filter_map s ~f:(fun (b', c) ->
           if Poly.equal b b' then Some (a, c) else None)))

  let diff (r : ('a, 'b) t) (s : ('a, 'b) t) : ('a, 'b) t =
    List.filter r ~f:(fun p -> not (List.mem s p ~equal:Poly.equal))

  let to_list (r : ('a, 'b) t) : ('a * 'b) list = r
end

(* --- the two formulations --------------------------------------------- *)

(* Transcribed from engine/tape_engine.ml's [correlate_image]. Kept as a
   literal copy rather than factored out of the engine: the point is to
   compare against what actually ships, so a divergence between this and
   the engine is itself a finding. *)
let loop_pairs (arr : Tape.choice array) : (int * int) list =
  let n = Array.length arr in
  let pairs = ref [] in
  for i = 0 to n - 1 do
    for j = 0 to n - 1 do
      if i <> j then
        match (arr.(i), arr.(j)) with
        | Tape.Integer a, Tape.Integer b
          when Int64.(a.lo = b.lo) && Int64.(a.hi = b.hi)
               && Int64.(a.value <> b.value) ->
          pairs := (i, j) :: !pairs
        | _ -> ()
    done
  done;
  List.rev !pairs

let rel_pairs (arr : Tape.choice array) : (int * int) list =
  (* Projected to plain tuples immediately: an inlined record cannot
     escape its match in OCaml, so [a] itself cannot be carried out. *)
  let indexed =
    Array.to_list arr
    |> List.filter_mapi ~f:(fun i c ->
         match c with
         | Tape.Integer { value; lo; hi } -> Some (i, value, lo, hi)
         | _ -> None)
  in
  let bounds =
    Rel.of_list (List.map indexed ~f:(fun (i, _, lo, hi) -> (i, (lo, hi))))
  in
  let values =
    Rel.of_list (List.map indexed ~f:(fun (i, value, _, _) -> (i, value)))
  in
  let shares_bounds = Rel.compose bounds (Rel.converse bounds) in
  let shares_value = Rel.compose values (Rel.converse values) in
  (* Subtracting [shares_value] removes the diagonal for free, since a
     choice always shares its own value -- that is the step the write-up
     calls out, and it is the reason no explicit i <> j is needed. *)
  Rel.to_list (Rel.diff shares_bounds shares_value)

(* --- the property ------------------------------------------------------ *)

let choice_gen =
  (* Bounds drawn from a deliberately tiny pool so that sharing is COMMON.
     With wide independent bounds almost no pair matches and the property
     passes vacuously -- the generator has to make the interesting case
     likely, or the test measures nothing. *)
  G.map
    (G.both
       (G.both (G.of_list [ 0L; 1L; 5L ]) (G.of_list [ 10L; 20L ]))
       (G.both
          (G.of_list [ 0L; 1L; 2L; 3L ])
          (G.of_list [ true; true; true; false ])))
    ~f:(fun ((lo, hi), (value, is_int)) ->
      if is_int then Tape.Integer { value; lo; hi }
      else Tape.Bool (Int64.equal value 0L))

let show_pairs ps =
  String.concat ~sep:" "
    (List.map ps ~f:(fun (i, j) -> Printf.sprintf "(%d,%d)" i j))

let () =
  let checked = ref 0 in
  let with_pairs = ref 0 in
  let failures = ref 0 in
  let report name ok detail =
    if not ok then Int.incr failures;
    Stdio.printf "  %s %-46s %s\n" (if ok then "ok  " else "FAIL") name detail
  in
  Stdio.printf "relational rewrite of correlate_image (issue #14)\n\n";

  (* Property-tested with tapecheck itself, which is what the write-up
     claimed and did not show. *)
  let result =
    Tape_engine.run
      (G.list choice_gen)
      ~test:(fun cs ->
        let arr = Array.of_list cs in
        Int.incr checked;
        let l = loop_pairs arr in
        if not (List.is_empty l) then Int.incr with_pairs;
        List.equal (fun (a, b) (c, d) -> a = c && b = d) l (rel_pairs arr))
      ~seed:20260808 ~count:5000 ~size:12
  in
  (match result with
   | Tape_engine.Passed _ ->
     report "pair list identical, as a LIST not a set" true
       (Printf.sprintf "%d cases, %d with a non-empty pair set" !checked
          !with_pairs)
   | Tape_engine.Failed { minimal; _ } ->
     let arr = Array.of_list minimal in
     report "pair list identical, as a LIST not a set" false
       (Printf.sprintf "counterexample of %d choices: loop=%s rel=%s"
          (Array.length arr)
          (show_pairs (loop_pairs arr))
          (show_pairs (rel_pairs arr))));

  (* The generator must actually produce sharing pairs, or the run above
     proves nothing. This is the check that the positive control is a
     control at all.

     Only meaningful when the property PASSED: a failing run stops at the
     first counterexample, so [checked] is however far it got, and
     reporting "vacuous" there would be a second, spurious failure
     pointing away from the real one. *)
  (match result with
   | Tape_engine.Failed _ ->
     Stdio.printf
       "  --   vacuity check skipped: the run stopped early at a \
        counterexample\n"
   | Tape_engine.Passed _ ->
     report "the property was not vacuous" (!with_pairs > 100)
       (Printf.sprintf "%d/%d cases had at least one candidate pair"
          !with_pairs !checked));

  (* Exhaustive small cases, because random lists of 12 rarely produce
     the degenerate shapes: all-equal values (empty pair set despite
     shared bounds), and a single choice. *)
  let exhaustive_ok = ref true in
  let vals = [ 0L; 1L ] and bnds = [ (0L, 10L); (1L, 10L) ] in
  let rec build n acc =
    if n = 0 then begin
      let arr = Array.of_list (List.rev acc) in
      if not
           (List.equal
              (fun (a, b) (c, d) -> a = c && b = d)
              (loop_pairs arr) (rel_pairs arr))
      then exhaustive_ok := false
    end
    else
      List.iter vals ~f:(fun value ->
        List.iter bnds ~f:(fun (lo, hi) ->
          build (n - 1) (Tape.Integer { value; lo; hi } :: acc)))
  in
  List.iter [ 1; 2; 3; 4 ] ~f:(fun n -> build n []);
  report "exhaustive over all n<=4 from 2 values x 2 bounds" !exhaustive_ok
    "4^4 + 4^3 + 4^2 + 4 shapes";

  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf "test_relations: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "test_relations: all passed\n"

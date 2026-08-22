(* Port of Hypothesis's tests/quality/test_poisoned_lists.py.

   The companion to test_poison (their test_poisoned_trees.py), and a
   sharper instrument: trees ask what fraction of poisoned positions
   reduce, whereas this asserts an EXACT minimum -- the shrunk
   counterexample must be a list of length exactly 1, i.e. [POISON] and
   nothing else. An exact-minimum assertion is what the guard suite was
   missing; every other quality check here is a rate.

   The shape that makes it hard, and it is deliberate on their part:

   - An element is POISON with probability p, and a poison element draws
     NOTHING further, while an ordinary element draws an extra integer
     0..10. So elements have different tape widths, and deleting the
     wrong span leaves a misaligned tail.
   - The poison selector's shrink target is "not poison". Shrinking
     therefore pushes AWAY from the very thing the property needs, and
     the engine has to keep one poison element while deleting every
     other element around it.
   - Matrices draw n and m and then n*m elements, so the length is a
     PRODUCT of two draws. Reaching one element needs both factors
     driven to 1 -- lowering either alone changes the element count by a
     multiple, which is the long-range-dependency shape self_len and
     lengthlist also live in.

   Hypothesis runs 4 seeds x 3 sizes x 2 probabilities x 2 container
   shapes and asserts length 1 on all 48. *)
open! Base
module G = Base_quickcheck.Generator

type elt =
  | Poison
  | Value of int

let is_poison = function Poison -> true | Value _ -> false

(* Their [Poisoned]: a weighted boolean, and on the poison branch the
   generator returns WITHOUT drawing the integer. Modelled with a
   uniform selector whose poison case sits at the far end from the
   shrink target, because [draw_boolean(p)] shrinks to False and False
   is the non-poison branch. Putting poison at 0 instead would make
   shrinking generate poison, which inverts the whole exercise. *)
let poisoned ~p_denom =
  G.bind (G.int_uniform_inclusive 0 (p_denom - 1)) ~f:(fun i ->
    if i = p_denom - 1 then G.return Poison
    else G.map (G.int_uniform_inclusive 0 10) ~f:(fun v -> Value v))

let linear_lists elements ~size =
  G.bind (G.int_uniform_inclusive 0 size) ~f:(fun n ->
    G.list_with_length elements ~length:n)

let matrices elements ~size =
  let side =
    Float.to_int (Float.round_up (Float.sqrt (Int.to_float size)))
  in
  G.bind (G.int_uniform_inclusive 0 side) ~f:(fun n ->
    G.bind (G.int_uniform_inclusive 0 side) ~f:(fun m ->
      G.list_with_length elements ~length:(n * m)))

(* Fails iff the container holds any poison, exactly as theirs does. *)
let test l = not (List.exists l ~f:is_poison)

let below_minimum = ref 0
let cases = ref 0
let not_found = ref 0
let truncated = ref 0
let lengths = ref []

let run_case ~name ~gen ~seed =
  Int.incr cases;
  match
    (* max_shrinks and max_stall raised well past what any of these
       runs use (the worst observed is ~1000 calls against a 20,000
       budget). [converged] is [budget_ok ()], which those two clear as
       well as ?budget does, so leaving them at their defaults made
       three cases report as cut-off when the point of the test is to
       measure where the search SETTLES. With them raised, every
       remaining failure is shrink quality and nothing else. *)
    Tape_engine.run gen ~test ~seed ~count:20_000 ~size:30 ~budget:20_000
      ~max_shrinks:5_000 ~max_stall:(Some 5_000)
  with
  | Tape_engine.Passed _ ->
    (* Distinguished from a quality failure on purpose: never finding a
       poisoned container means the GENERATION budget was too small for
       this p, which is a different complaint from shrinking badly, and
       reporting them together would hide both. *)
    Int.incr not_found;
    Stdio.printf "    ....  %-34s seed %-20d never found poison\n" name seed
  | Tape_engine.Failed { minimal; converged; attempts; _ } ->
    let n = List.length minimal in
    lengths := n :: !lengths;
    if not converged then Int.incr truncated;
    if n <> 1 then begin
      Int.incr below_minimum;
      (* [converged] separates "the search settled here" from "the
         budget ran out", which are different complaints: the first is a
         shrink-quality gap, the second just means [budget] is too
         small. Reporting them together would let a budget problem
         masquerade as a quality frontier. *)
      Stdio.printf
        "    gap   %-34s seed %-20d len %-3d %s (%d calls)\n" name seed n
        (if converged then "settled" else "TRUNCATED")
        attempts
    end

let () =
  Stdio.printf
    "poisoned containers (Hypothesis tests/quality/test_poisoned_lists.py)\n\n\
    \  Exact-minimum assertion: the shrunk counterexample must be a list\n\
    \  of length exactly 1. Hypothesis passes all 48 of these.\n\n";
  (* Their seeds, verbatim, except the third: 14202812238092722246
     cannot even be WRITTEN as an OCaml int literal (native int is 63
     bits). Reduced mod 2^62 to 367754182810558534 -- still an arbitrary
     constant, which is the only property a seed needs, and not one
     picked because it passes. *)
  let seeds =
    [ 2282791295271755424; 1284235381287210546; 367754182810558534; 26097 ]
  in
  List.iter [ ("LinearLists", linear_lists); ("Matrices", matrices) ]
    ~f:(fun (cname, ctor) ->
      List.iter [ 5; 10; 20 ] ~f:(fun size ->
        List.iter [ 100; 10 ] ~f:(fun p_denom ->
          let name =
            Printf.sprintf "%s size=%d p=1/%d" cname size p_denom
          in
          let gen = ctor (poisoned ~p_denom) ~size in
          List.iter seeds ~f:(fun seed -> run_case ~name ~gen ~seed))));

  let found = List.length !lengths in
  let exact = List.count !lengths ~f:(fun n -> n = 1) in
  Stdio.printf "\n  %d/%d cases found poison; %d/%d of those shrank to length 1\n"
    found !cases exact found;
  (match !lengths with
   | [] -> ()
   | l ->
     let mx = List.fold l ~init:0 ~f:Int.max in
     Stdio.printf "  worst minimal length: %d\n" mx);
  if !truncated > 0 then
    Stdio.printf
      "  %d case(s) still cut off rather than settled -- NOT ?budget \
       (unused); [converged] is also cleared by max_shrinks/max_stall, so \
       raise those before reading these as quality\n"
      !truncated;
  if !not_found > 0 then
    Stdio.printf
      "  %d case(s) never found poison -- generation budget, not shrink \
       quality\n"
      !not_found;
  Stdio.printf "\n";

  (* Hypothesis reaches 48/48; this engine reaches 21/48 and the gap is real.
     These cases and seeds are deterministic, so pin the measured result
     rather than allowing it to decay behind a floor. A regression or an
     improvement moves the published frontier and requires updating
     CHALLENGE.md, the comparison board, and this test.

     Two further live assertions prevent a broken benchmark from preserving
     the headline accidentally: every case must find poison, and none may be
     cut off, since a cut-off run measures the cutoff rather than the
     shrinker. *)
  let recorded = 21 in
  let ok = ref true in
  if found <> !cases then begin
    ok := false;
    Stdio.printf
      "  FAIL  the benchmark did not run: %d/%d cases found poison\n" found
      !cases
  end;
  if !truncated > 0 then begin
    ok := false;
    Stdio.printf
      "  FAIL  %d case(s) cut off; this measures the cutoff, not the \
       shrinker\n"
      !truncated
  end;
  if exact <> recorded then begin
    ok := false;
    Stdio.printf
      "  FAIL  exact minima %d differs from recorded %d. The frontier moved \
       -- review it and update CHALLENGE.md.\n"
      exact recorded
  end
  else
    Stdio.printf
      "  ok    exact minima %d/%d (recorded exactly, Hypothesis 48/48)\n"
      exact found;

  if not !ok then begin
    Stdio.printf
      "\n  See LENGTH-REPAIR.md: the length-reduction move that would close\n\
      \  this is ported but inert under the current pass order.\n";
    Stdlib.exit 1
  end

(* RO5 half 2 (outreach/ro-roadmap.md): demonstrates the paper's own
   motivating case for Phase.explain's input-side analysis ("Property-
   Based Testing in Practice", ICSE 2024). Quoting the concern this
   feature answers: shrink a bug to (0, 0) and a reader may wrongly
   conclude any tuple triggers it, when in fact only the first
   component being 0 matters.

   The property below fails iff the first component of the pair is
   exactly 0 (think: a division-by-zero-shaped bug keyed only on the
   first argument). Base_quickcheck's own greedy shrinker, and the tape
   engine's own shrinker, both minimize this to exactly (0, 0) --
   correctly, but the second 0 invites the wrong inference. This demo
   shows the free-variation analysis catching exactly that: it reports
   the second component as varying freely (many other values of b still
   fail) while the first is never found to vary (every alternative
   tried makes the test pass). *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

let gen = G.both (G.int_uniform_inclusive 0 1000) (G.int_uniform_inclusive 0 1000)

(* The "bug": fails (returns false) iff the first component is 0. The
   second component is a complete red herring for this test. *)
let test (a, _b) = a <> 0

let () =
  printf "Property: pair (a, b) in [0,1000]^2, fails iff a = 0\n";
  printf "(the paper's own motivating case for explain: a minimal example\n";
  printf " of (0, 0) invites the wrong guess that b = 0 matters too)\n\n";
  match Tape_engine.run gen ~test ~seed:0 ~count:200 ~size:10 ~budget:2000 with
  | Tape_engine.Passed _ -> printf "no failure found (unexpected)\n"
  | Tape_engine.Failed { minimal; original; attempts; image; trail; _ } ->
    printf "original failing example: %s\n"
      (Sexp.to_string ([%sexp_of: int * int] original));
    printf "minimal example:          %s  (%d shrink attempts)\n\n"
      (Sexp.to_string ([%sexp_of: int * int] minimal))
      attempts;
    (* Secondary output: the trail of accepted intermediate shrinks
       (cheap to keep -- images, not materialized values). *)
    printf "accepted-shrink trail (%d steps), each replayed to show what it built:\n"
      (List.length trail);
    List.iteri trail ~f:(fun i img ->
      let v, () = Tape_engine.replay_image_and_apply gen ~size:10 img ~f:(fun _ -> ()) in
      printf "  step %2d: %s\n" i (Sexp.to_string ([%sexp_of: int * int] v)));
    printf "\n";
    (* The actual answer to the paper's complaint: free-variation
       analysis over the minimal tape's individual choices. *)
    let t0 = Stdlib.Sys.time () in
    let report =
      Tape_explain.analyze ~gen ~size:10 ~test
        ~attempts_per_choice:Tape_explain.default_attempts_per_choice ~trail
        image
    in
    let elapsed = Stdlib.Sys.time () -. t0 in
    printf "%s\n" (Tape_explain.to_string_hum ~sexp_of:[%sexp_of: int * int] report);
    printf "explain phase cost: %.4fs wall, %d replays (up to %d per choice)\n"
      elapsed report.used report.attempts_per_choice;
    (* Sanity check for the demo itself: fail loudly if the analysis
       does not actually distinguish the two components the way the
       paper's story requires, rather than silently printing a report
       that doesn't demonstrate the point. *)
    let is_free = function
      | { Tape_explain.outcome = Tape_explain.Varies _; _ } -> true
      | _ -> false
    in
    let a_choice, b_choice =
      match report.choices with
      | [ a; b ] -> (a, b)
      | _ ->
        failwith
          "expected exactly two main-stream choices for a (int, int) pair"
    in
    if is_free a_choice then
      failwith
        "demo invariant violated: the first component (load-bearing, must be \
         0) was reported as free"
    else if not (is_free b_choice) then
      failwith
        "demo invariant violated: the second component (a red herring) was \
         not reported as free"
    else
      printf
        "\nConfirmed: analysis reports the LOAD-BEARING first component as \
         no-variation-found, and the RED-HERRING second component as \
         varying freely -- exactly the distinction the paper asks for.\n"

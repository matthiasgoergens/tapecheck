(* RO6 demo (outreach/ro-roadmap.md): the ICSE 2024 paper's own scenario,
   reproduced directly -- "tools should always announce counts of
   discarded test cases... OCaml's QuickCheck hides output when tests
   succeed, which obscures that information" (outreach/paper-full.txt).

   Property: every perfect square in [0, 100_000] has an exact integer
   square root. Written the textbook way, with a precondition filtered
   by assume(): perfect squares are about 1% of the range (316 of
   100_001 values), so roughly 99 cases out of every 100 generated are
   thrown away before the property body ever runs. The test is GREEN --
   it always passes on the 1% that survive -- while testing almost
   nothing. This is exactly the gap RO6 names, and exactly what
   filter_too_much is for. *)

open! Base
open Stdio

let sqrt_exact x =
  let r = Int.of_float (Float.round_nearest (Float.sqrt (Float.of_int x))) in
  r * r = x

module M = struct
  type t = int [@@deriving sexp_of]

  let quickcheck_generator = Base_quickcheck.Generator.int_uniform_inclusive 0 100_000
  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

(* The narrow-generator fix module (scenario 3): sample a perfect
   square DIRECTLY (an integer root in [0, 316], squared) instead of
   generating any integer and filtering -- Hypothesis's own advice for
   this exact shape ("integers().filter(x > 0)" -> "integers(min_value=1)",
   outreach/hypothesis-inventory.md section 6). No case is ever
   discarded, because every generated value already satisfies the
   precondition by construction. *)
module M_narrow = struct
  type t = int [@@deriving sexp_of]

  let quickcheck_generator =
    Base_quickcheck.Generator.map
      (Base_quickcheck.Generator.int_uniform_inclusive 0 316)
      ~f:(fun r -> r * r)

  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

let filtered_property (x : int) : unit Or_error.t =
  Tape_test.assume (sqrt_exact x);
  (* Reachable on ~1% of generated cases; always true here, by
     construction of the property under test. *)
  if sqrt_exact x then Ok () else Or_error.error_string "sqrt_exact broken"

let narrow_property (x : int) : unit Or_error.t =
  (* No assume needed: every value M_narrow generates already is a
     perfect square. *)
  if sqrt_exact x then Ok () else Or_error.error_string "sqrt_exact broken"

let small_config =
  { Tape_test.default_config with Base_quickcheck.Test.Config.test_count = 2000 }

let () =
  printf "===========================================================\n";
  printf " Scenario 1: heavy filtering, health check ON (the default)\n";
  printf "===========================================================\n";
  printf
    "Property: for x in [0, 100_000], if x is a perfect square then its\n\
     integer sqrt squares back to x -- checked via assume(is_square x).\n\
     About 316 of 100_001 values (0.3%%) are perfect squares, so almost\n\
     every generated case is discarded before the property body runs.\n\n";
  (* A health check fires as a raw, uncaught-by-Or_error exception (the
     same "loud, not silent" posture this codebase already gives a
     corrupt regression tape -- see engine/tape_test.ml's
     [Regressions.load]), so it is caught here directly rather than via
     the Ok/Error channel a genuine test failure comes back on. *)
  (try
     match Tape_test.run ~f:filtered_property ~config:small_config (module M) with
     | Ok () -> printf "unexpected: no health check fired\n\n"
     | Error e ->
       printf "unexpected genuine test failure: %s\n\n" (Error.to_string_hum e)
   with exn ->
     printf "CAUGHT, as intended -- a green test just turned red:\n\n%s\n\n"
       (Exn.to_string exn));

  printf "===========================================================\n";
  printf " Scenario 2: same filtering, health check suppressed\n";
  printf "===========================================================\n";
  printf
    "Same property, same filtering ratio, but with\n\
     ~suppress_health_check:[Tape_health.Filter_too_much]. This is what\n\
     a run looked like before this port: it passes, silently, with no\n\
     indication that almost every case was thrown away -- the paper's\n\
     complaint, verbatim (\"OCaml's QuickCheck hides output when tests\n\
     succeed\"). ?report:`Full is added here ONLY to show what the run\n\
     actually did; it plays no role in suppressing the health check.\n\n";
  (match
     Tape_test.run ~f:filtered_property ~config:small_config
       ~suppress_health_check:[ Tape_health.Filter_too_much ] ~report:`Full
       (module M)
   with
   | Ok () -> printf "(the summary/discard count above is the fix: RO6's\n ask, answered, independent of whether the health check itself fires)\n\n"
   | Error e -> printf "unexpected failure: %s\n\n" (Error.to_string_hum e));

  printf "===========================================================\n";
  printf " Scenario 3: the actual fix -- narrow the generator\n";
  printf "===========================================================\n";
  printf
    "Same property, but the generator samples a perfect square DIRECTLY\n\
     (an integer root in [0, 316], squared) instead of filtering after\n\
     the fact -- Hypothesis's own advice for this shape. No case is\n\
     ever discarded, because every generated value already satisfies\n\
     the precondition by construction.\n\n";
  (match
     Tape_test.run ~f:narrow_property ~config:small_config ~report:`Full
       (module M_narrow)
   with
   | Ok () -> printf "PASSED cleanly -- no discards, no warnings.\n"
   | Error e -> printf "unexpected failure: %s\n" (Error.to_string_hum e))

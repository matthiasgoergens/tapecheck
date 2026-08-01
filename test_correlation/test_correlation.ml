(* Guards the correlated-value mutation.

   Bugs that need two values to COINCIDE are essentially unreachable by
   independent sampling once the range is wide: measured 32/200 at range
   100_000 before the mutation existed, 200/200 after. This pins that,
   because losing it would be invisible -- the property would simply
   "not fail", which reads as a passing test. *)
open Base
module G = Base_quickcheck.Generator

let wide = G.int_uniform_inclusive 0 100_000

let () =
  (* The hardest measured case: two independent draws from a 100_000-wide
     range must coincide. Floor of 90% leaves room for seed variation
     while catching the mutation being lost entirely. *)
  Test_support.find_any ~name:"pair a = b over 0..100_000"
    ~gen:(G.both wide wide)
    ~test:(fun (a, b) -> a <> b)
    ();
  Test_support.find_any ~name:"duplicate in list over 0..100_000"
    ~gen:(G.list wide)
    ~test:(fun l ->
      let rec go = function
        | [] | [ _ ] -> true
        | x :: rest -> (not (List.mem rest x ~equal:Int.equal)) && go rest
      in
      go l)
    ();
  (* Opposite direction, and the reason it is here: [find_any] alone
     cannot distinguish "the engine finds correlations" from "the engine
     reports failures indiscriminately". A property that must never fail
     rules the second reading out. *)
  Test_support.assert_no_failure ~name:"a = a always holds"
    ~gen:(G.both wide wide)
    ~test:(fun (a, _) -> a = a)
    ();
  (* Through the PUBLIC api, not Tape_engine.run directly.

     The two checks above drive the engine themselves with ~count:200,
     which is what the mutation's own benchmark does. Tape_test.result
     -- the entry point real users go through -- calls run once per size
     with ~count:1, and the mutation used to be gated on a per-call case
     index that is therefore always 0. It never fired for anyone. A
     capability tested only via the interface its implementation
     happens to use is not tested. *)
  let found = ref 0 in
  let runs = 30 in
  for t = 0 to runs - 1 do
    let module Pair = struct
      type t = int * int [@@deriving sexp_of]

      let quickcheck_generator = G.both wide wide
      let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
    end in
    let r =
      Tape_test.run
        ~f:(fun (a, b) ->
          if a = b then Or_error.error_string "coincidence" else Ok ())
        ~config:
          { Base_quickcheck.Test.default_config with
            test_count = 400
          ; seed =
              Base_quickcheck.Test.Config.Seed.Deterministic
                (Int.to_string (t * 7919))
          }
        (module Pair)
    in
    if Result.is_error r then Int.incr found
  done;
  Test_support.report "correlation reachable through Tape_test"
    (!found * 100 / runs >= 80)
    (Printf.sprintf "found %d/%d (need 80%%)" !found runs);
  Test_support.finish ()

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
  Test_support.finish ()

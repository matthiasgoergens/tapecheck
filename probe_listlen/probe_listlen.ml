(* A list's LENGTH stops shrinking when its elements are compound.

   Same property, same seed, same size, same budget. The only thing that
   changes is the element generator:

     G.list (G.int_uniform_inclusive 0 1000)  ->  reaches length 10
     G.list G.string                          ->  stuck at length 30

   The property is [List.length l < 10], so the answer is a list of
   exactly 10 elements, and the int case finds it. The string case does
   not move the length AT ALL -- and reports converged = true, meaning
   the engine believes it settled rather than ran out of budget. Raising
   the budget a hundredfold changes nothing (2424 attempts used of
   200000 available).

   Found while checking whether a string-aware shrink pass would fix
   test_shrink_quality's "list of strings shrinks to 10 empty strings".
   It would not: that case is not about strings. Its outer list length
   is the thing that will not come down.

   WHY IT LOOKS LIKE AN ENCODING PROBLEM. base_quickcheck draws a list
   length with Splittable_random.Log_uniform.int, which is TWO choices
   where the second's bounds depend on the first (sr_real.ml:331):

     let bits = int state ~lo:min_bits ~hi:max_bits in
     uniform state ~lo:(min_represented_by_n_bits bits |> max lo)
                   ~hi:(max_represented_by_n_bits bits |> min hi)

   In the stuck tape those are positions 0 and 1:

     0  Integer 5  [0,5]     <- bits
     1  Integer 30 [16,30]   <- value, bounds are a function of bits

   Lowering bits 5 -> 4 should retarget the value into [8,15], giving
   length 15, which still fails the property and yields a much shorter
   tape (fewer elements, and [sizes] emits a Fisher-Yates permutation
   draw per element -- positions 2..30 in the same tape are exactly that
   loop). It should be accepted, and then a binary search inside [8,15]
   should land on 10. In the minimal image, position 0 is still 5.

   So this is a coordinated two-choice move where the second choice's
   DOMAIN moves, which is a different shape from lower_together's
   value-preserving pair edit.

   Not diagnosed further and not fixed here: recorded as a reproducer so
   the next person starts from a measurement rather than from the
   string-shaped symptom. *)
open! Base

module G = Base_quickcheck.Generator

let case name gen show =
  match
    Tape_engine.run gen
      ~test:(fun l -> List.length l < 10)
      ~seed:7 ~count:400 ~size:30 ~budget:50_000 ~max_shrinks:5_000
  with
  | Tape_engine.Passed _ -> Stdio.printf "  %-28s no failure found\n" name
  | Tape_engine.Failed { minimal; image; attempts; converged; _ } ->
    Stdio.printf
      "  %-28s len %-4d tape %-4d attempts %-6d converged %-5b %s\n" name
      (List.length minimal)
      (Array.length image.Tape.main)
      attempts converged (show minimal)

let () =
  Stdio.printf
    "fails iff length >= 10, so the answer is a list of exactly 10\n\n";
  case "int list, size 30"
    (G.list (G.int_uniform_inclusive 0 1000))
    (fun l -> Printf.sprintf "%d ints" (List.length l));
  case "string list, size 30" (G.list G.string) (fun l ->
    Printf.sprintf "%d chars total" (List.sum (module Int) l ~f:String.length));
  Stdio.printf
    "\nthe int case reaches the answer; the string case never lowers the\n\
     length, and says it converged while doing so\n"

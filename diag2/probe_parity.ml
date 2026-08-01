(* Does tapecheck's integer shrinking have falsify's parity bias?

   falsify documents it (Internal/Search.hs): standard binary search
   "is not very good at allowing search to flip between even and odd.
   For example, if we start with maxBound, EVERY possible shrunk value
   computed by binarySearch is even." They ship
   binarySearchNoParityBias to counter it.

   tapecheck's minimize_integer is a plain halving search, so the same
   bias is plausible. The test: a property failing iff v >= T, for many
   T of each parity. The true minimum IS T, so any shortfall on odd T
   relative to even T is the bias showing. *)
open Base
module G = Base_quickcheck.Generator

let exact_for threshold =
  let hits = ref 0 and n = ref 0 in
  for t = 0 to 39 do
    match
      Tape_engine.run
        (G.int_uniform_inclusive 0 1_000_000)
        ~test:(fun v -> v < threshold)
        ~seed:(t * 7919) ~count:300 ~size:10
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; _ } ->
      Int.incr n;
      if minimal = threshold then Int.incr hits
  done;
  (!hits, !n)

let () =
  Stdio.printf "exact-minimum rate by threshold parity\n\n";
  let evens = [ 100; 256; 1000; 4096; 12_346; 65_536 ] in
  let odds = [ 101; 257; 1001; 4097; 12_345; 65_537 ] in
  let run label ts =
    let h, n =
      List.fold ts ~init:(0, 0) ~f:(fun (ah, an) t ->
        let h, n = exact_for t in
        Stdio.printf "  %-5s T=%-7d exact %2d/%2d\n" label t h n;
        (ah + h, an + n))
    in
    Stdio.printf "  %-5s TOTAL       exact %2d/%2d (%.0f%%)\n\n" label h n
      (100. *. Float.of_int h /. Float.of_int (Int.max 1 n));
    (h, n)
  in
  let eh, en = run "even" evens in
  let oh, on = run "odd" odds in
  Stdio.printf "even %.0f%%  vs  odd %.0f%%\n"
    (100. *. Float.of_int eh /. Float.of_int (Int.max 1 en))
    (100. *. Float.of_int oh /. Float.of_int (Int.max 1 on))

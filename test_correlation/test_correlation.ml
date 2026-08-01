(* Guards the correlated-value mutation.

   Bugs that need two values to COINCIDE are essentially unreachable by
   independent sampling once the range is wide: measured 32/200 at range
   100_000 before the mutation existed. The mutation takes it to 200/200.
   This pins that, because losing it would be invisible -- the property
   would simply "not fail", which reads as a passing test. *)
open Base
module G = Base_quickcheck.Generator

let find_rate ~gen ~test ~runs =
  let found = ref 0 in
  for t = 0 to runs - 1 do
    match Tape_engine.run gen ~test ~seed:(t * 7919) ~count:200 ~size:10 with
    | Tape_engine.Failed _ -> Int.incr found
    | Tape_engine.Passed _ -> ()
  done;
  !found

let () =
  let runs = 100 in
  (* The hardest of the measured cases: two independent draws from a
     100_000-wide range must land on the same value. *)
  let pair_wide =
    find_rate ~runs
      ~gen:
        (G.both
           (G.int_uniform_inclusive 0 100_000)
           (G.int_uniform_inclusive 0 100_000))
      ~test:(fun (a, b) -> a <> b)
  in
  let dup_wide =
    find_rate ~runs
      ~gen:(G.list (G.int_uniform_inclusive 0 100_000))
      ~test:(fun l ->
        let rec go = function
          | [] | [ _ ] -> true
          | x :: rest -> (not (List.mem rest x ~equal:Int.equal)) && go rest
        in
        go l)
  in
  Stdio.printf "pair a = b over 0..100_000:      found %d/%d\n" pair_wide runs;
  Stdio.printf "duplicate in list over 0..100_000: found %d/%d\n" dup_wide runs;
  (* Before the mutation these were 32/200 and 165/200 respectively. A
     floor of 90% leaves room for seed variation while catching the
     mutation being lost entirely. *)
  let ok = pair_wide >= 90 && dup_wide >= 90 in
  Stdio.printf "\n  correlated-value bugs still findable: %b\n" ok;
  if not ok then begin
    Stdio.printf "  FAIL: the correlation mutation looks lost (was 32/200 without it)\n";
    Stdlib.exit 1
  end

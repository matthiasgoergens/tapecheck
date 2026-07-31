(* RO6 (outreach/ro-roadmap.md), requirement: "overhead on the passing
   path must be negligible -- this is the path that runs constantly in
   CI." This measures exactly that: the current [Tape_engine.run]
   generate-phase loop, which now always does case accounting (valid/
   invalid/failing counts), event-bag bookkeeping (Tape_stats.begin_case/
   take_events, a Hashtbl clear+merge per case even when the property
   never calls [event]), health-check bookkeeping (Tape_health.record,
   plus one extra generation replay for the large_base_example check
   the very first time), and two Stdlib.Sys.time() calls per case for
   the generate/run time split -- against a HAND-ROLLED loop doing
   exactly the same generate+test work with NONE of that, i.e.
   reproducing this repo's pre-RO6 [run_and_test] body verbatim.

   Methodology matches bench_intercept/ and
   design/intercept-overhead-results.txt: many reps per arm, alternating
   arms to spread thermal/scheduling drift, accumulators printed so
   neither loop can be dead-code-eliminated and so both arms are
   confirmed to do the same amount of real work (same accumulator value
   both ways, since the property always passes and the generator is
   deterministic per seed). *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

let cases = 500_000
let reps = 5

let gen = G.int_uniform_inclusive 0 1000
let test (_ : int) = true

(* Exactly the pre-RO6 run_and_test body and [run]'s own generate-phase
   loop shape (ONE tape object reused across cases via
   start_recording, matching [Tape_engine.run] precisely, so the only
   difference from [current_loop] is the RO6 bookkeeping itself): no
   Tape_stats, no Tape_health, no Sys.time. *)
let baseline_once tape seed =
  Tape.start_recording tape;
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
  in
  let value = G.generate gen ~size:10 ~random in
  let passed = test value in
  let _out = Tape.finish tape in
  if passed then 1 else 0

let baseline_loop () =
  let tape = Tape.create () in
  let acc = ref 0 in
  for i = 0 to cases - 1 do
    acc := !acc + baseline_once tape i
  done;
  !acc

let current_loop () =
  match Tape_engine.run gen ~test ~count:cases ~seed:0 with
  | Tape_engine.Passed { cases = n } -> n
  | Tape_engine.Failed _ -> failwith "unexpected failure in overhead bench"

(* Second scenario: many SMALL calls sharing one [stats]/[health], each
   generating exactly one case -- the actual shape [Tape_test.result]
   uses (one Tape_engine.run call per size value, config.test_count of
   them, 10,000 by default), rather than one call generating [cases]
   cases. Checks that per-CALL overhead (a fresh [Tape.create ()] plus
   [Tape_health.state]/[stats] lookups) doesn't reintroduce cost this
   scenario's single-big-call measurement above wouldn't catch. *)
let many_calls = 20_000

let baseline_many_calls_loop () =
  let acc = ref 0 in
  for i = 0 to many_calls - 1 do
    let tape = Tape.create () in
    acc := !acc + baseline_once tape i
  done;
  !acc

let current_many_calls_loop () =
  let stats = Tape_engine.no_stats () in
  let health = Tape_health.create () in
  let acc = ref 0 in
  for i = 0 to many_calls - 1 do
    match Tape_engine.run gen ~test ~count:1 ~seed:i ~stats ~health with
    | Tape_engine.Passed { cases } -> acc := !acc + cases
    | Tape_engine.Failed _ -> failwith "unexpected failure in overhead bench"
  done;
  !acc

let check_here name cond = if not cond then failwith ("FAILED: " ^ name)

let time_it f =
  let t0 = Stdlib.Sys.time () in
  let r = f () in
  let t1 = Stdlib.Sys.time () in
  (r, t1 -. t0)

let () =
  printf "Passing-path overhead: %d cases/rep, %d reps, alternating arms\n\n"
    cases reps;
  let baseline_times = ref [] in
  let current_times = ref [] in
  for rep = 0 to reps - 1 do
    let acc_b, t_b = time_it baseline_loop in
    let acc_c, t_c = time_it current_loop in
    check_here "same accumulator (baseline vs current do equal real work)"
      (acc_b = acc_c);
    printf "  rep %d: baseline %.4fs (%.1f ns/case)   current %.4fs (%.1f ns/case)\n"
      rep t_b
      (t_b /. Float.of_int cases *. 1e9)
      t_c
      (t_c /. Float.of_int cases *. 1e9);
    baseline_times := t_b :: !baseline_times;
    current_times := t_c :: !current_times
  done;
  let min_of l = List.reduce_exn l ~f:Float.min in
  let b_min = min_of !baseline_times and c_min = min_of !current_times in
  let ns_per_case t = t /. Float.of_int cases *. 1e9 in
  printf "\nbest-of-%d: baseline %.1f ns/case, current %.1f ns/case, delta %+.1f ns/case (%+.1f%%)\n"
    reps (ns_per_case b_min) (ns_per_case c_min)
    (ns_per_case c_min -. ns_per_case b_min)
    ((ns_per_case c_min -. ns_per_case b_min) /. ns_per_case b_min *. 100.);

  printf
    "\n\
     Second scenario: %d SEPARATE one-case Tape_engine.run calls sharing\n\
     one stats/health (Tape_test.result's actual shape) vs the same many-\n\
     small-calls pattern with no bookkeeping\n\n"
    many_calls;
  let baseline_times2 = ref [] in
  let current_times2 = ref [] in
  for rep = 0 to reps - 1 do
    let acc_b, t_b = time_it baseline_many_calls_loop in
    let acc_c, t_c = time_it current_many_calls_loop in
    check_here "second scenario: same accumulator" (acc_b = acc_c);
    printf "  rep %d: baseline %.4fs (%.1f ns/case)   current %.4fs (%.1f ns/case)\n"
      rep t_b
      (t_b /. Float.of_int many_calls *. 1e9)
      t_c
      (t_c /. Float.of_int many_calls *. 1e9);
    baseline_times2 := t_b :: !baseline_times2;
    current_times2 := t_c :: !current_times2
  done;
  let b_min2 = min_of !baseline_times2 and c_min2 = min_of !current_times2 in
  let ns_per_case2 t = t /. Float.of_int many_calls *. 1e9 in
  printf
    "\nbest-of-%d: baseline %.1f ns/case, current %.1f ns/case, delta %+.1f ns/case (%+.1f%%)\n"
    reps (ns_per_case2 b_min2) (ns_per_case2 c_min2)
    (ns_per_case2 c_min2 -. ns_per_case2 b_min2)
    ((ns_per_case2 c_min2 -. ns_per_case2 b_min2) /. ns_per_case2 b_min2 *. 100.)

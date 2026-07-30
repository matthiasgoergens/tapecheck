(* Measured before/after numbers for the edge-case-biased generation
   port (tape/tape.ml), ported from Python Hypothesis's Conjecture
   provider (outreach/hypothesis-sources/providers_hypothesis.py)
   via the shape of the sibling Rust port (proptest-rs/proptest,
   test_runner/runner.rs). "Stock" below always means: generate
   through the vendored base_quickcheck with NO tape attached at all
   (Splittable_random.of_int with no [For_tape.attach]), which is the
   plain, always-uniform code path and is therefore unaffected by any
   change to tape.ml -- exactly the same "stock" arm demo/shrink_table.ml
   uses for its results table. "Tape" means generation through a
   recording tape, which is where this port's bias lives. *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

(* ---- 1. Divisibility hit-rate (proptest-rs/proptest upstream issue
   #500): a paging computation total_count / count + 1 is wrong
   exactly when total_count mod count = 0. Uniform sampling over
   total_count in [0, 1_000_000], count in [1, 100_000] hits a
   multiple only about 1 in 10^4-10^5 times (count=1 divides
   everything, and roughly 1/count of the range are multiples of
   count, averaged over count -- see the write-up for the back-of
   -envelope). Edge-case biasing should hit it far more often via
   total_count=0 (a multiple of everything) or count=1 (divides
   everything), both boundary candidates. ---- *)

let divisibility_hit ~total_count ~count = total_count % count = 0

let measure_stock_hitrate ~n =
  let hits = ref 0 in
  for i = 0 to n - 1 do
    let random = Splittable_random.of_int i in
    let total_count =
      G.generate (G.int_uniform_inclusive 0 1_000_000) ~size:30 ~random
    in
    let count = G.generate (G.int_uniform_inclusive 1 100_000) ~size:30 ~random in
    if divisibility_hit ~total_count ~count then Int.incr hits
  done;
  !hits

let measure_tape_hitrate ~n =
  let hits = ref 0 in
  let tape = Tape.create () in
  for i = 0 to n - 1 do
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int i) tape
    in
    let total_count =
      G.generate (G.int_uniform_inclusive 0 1_000_000) ~size:30 ~random
    in
    let count = G.generate (G.int_uniform_inclusive 1 100_000) ~size:30 ~random in
    ignore (Tape.finish tape : Tape.output);
    if divisibility_hit ~total_count ~count then Int.incr hits
  done;
  !hits

(* End-to-end version: does Tape_engine.run's generate+shrink loop find
   the bug AND shrink it to the true global minimum (0, 1), over many
   seeds, mirroring demo/shrink_table.ml's methodology (100 seeds, 200
   cases/trial). *)
let measure_divisibility_engine ~trials ~cases_per_trial =
  let found = ref 0 and minimal = ref 0 in
  for trial = 0 to trials - 1 do
    let seed = trial * 1_000_003 in
    let gen =
      G.both (G.int_uniform_inclusive 0 1_000_000) (G.int_uniform_inclusive 1 100_000)
    in
    match
      Tape_engine.run gen ~seed ~count:cases_per_trial ~size:30 ~budget:5000
        ~test:(fun (total_count, count) -> not (divisibility_hit ~total_count ~count))
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; _ } ->
      Int.incr found;
      if Poly.equal m (0, 1) then Int.incr minimal
  done;
  (!found, !minimal, trials)

(* ---- 2. Full int64 range: does generation actually produce
   Int64.min_value? Uniform-only sampling hits any single value with
   probability 1/2^64 -- "virtually never" in the README's original
   phrasing. Edge-case biasing makes min_int a boundary candidate. ---- *)

let measure_min_int_stock ~seeds ~cases_per_seed =
  let hits = ref 0 in
  for seed = 0 to seeds - 1 do
    for case = 0 to cases_per_seed - 1 do
      let random = Splittable_random.of_int ((seed * 1_000_003) + case) in
      let v = G.generate G.int64_uniform ~size:30 ~random in
      if Int64.equal v Int64.min_value then Int.incr hits
    done
  done;
  !hits

let measure_min_int_tape () =
  Tape_engine.run G.int64_uniform ~count:2000 ~size:30
    ~test:(fun v -> not (Int64.equal v Int64.min_value))

(* ---- 3. Generation-path performance cost: ns/draw for a fresh
   Integer draw under a recording tape (where biasing applies), vs the
   same draw with no tape attached at all (plain uniform, the pre
   -existing tapecheck cost with the bias feature entirely absent from
   the code path). Both numbers come from the SAME build; run this
   file again against a stashed (pre-bias) tape.ml for the "before"
   half of the tape-recording row -- see the write-up. ---- *)

let time_draws ~label ~n ~f =
  let t0 = Unix.gettimeofday () in
  f n;
  let t1 = Unix.gettimeofday () in
  let secs = t1 -. t0 in
  printf "  %-28s %8d draws in %7.4fs  (%6.1f ns/draw)\n" label n secs
    (secs *. 1e9 /. Float.of_int n)

let time_tape_recording n =
  let tape = Tape.create () in
  for i = 0 to n - 1 do
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int i) tape
    in
    ignore (G.generate (G.int_uniform_inclusive 0 1_000_000) ~size:30 ~random : int);
    ignore (Tape.finish tape : Tape.output)
  done

let time_no_tape n =
  for i = 0 to n - 1 do
    let random = Splittable_random.of_int i in
    ignore (G.generate (G.int_uniform_inclusive 0 1_000_000) ~size:30 ~random : int)
  done

let () =
  printf "=== 1. Divisibility hit-rate (proptest upstream issue #500) ===\n";
  printf "total_count in [0, 1_000_000], count in [1, 100_000], hit iff total_count mod count = 0\n";
  let n_hitrate = 200_000 in
  let stock_hits = measure_stock_hitrate ~n:n_hitrate in
  let tape_hits = measure_tape_hitrate ~n:n_hitrate in
  printf "  stock (no tape, uniform): %6d / %d hits  (%.6f%%)\n" stock_hits n_hitrate
    (100. *. Float.of_int stock_hits /. Float.of_int n_hitrate);
  printf "  tape  (edge-case biased): %6d / %d hits  (%.4f%%)\n" tape_hits n_hitrate
    (100. *. Float.of_int tape_hits /. Float.of_int n_hitrate);
  printf "\n";

  printf "=== 1b. End-to-end: Tape_engine.run finds + fully minimizes to (0, 1) ===\n";
  let trials = 100 and cases_per_trial = 200 in
  let found, minimal, total = measure_divisibility_engine ~trials ~cases_per_trial in
  printf "  tape: found %d/%d, fully minimal to (0,1) %d/%d\n" found total minimal total;
  printf "\n";

  printf "=== 2. Full int64 range: does generation ever produce min_int? ===\n";
  let seeds = 100 and cases_per_seed = 2000 in
  let stock_min_int_hits = measure_min_int_stock ~seeds ~cases_per_seed in
  printf "  stock (no tape, uniform): %d / %d draws hit min_int\n" stock_min_int_hits
    (seeds * cases_per_seed);
  (match measure_min_int_tape () with
  | Tape_engine.Passed { cases } ->
    printf "  tape: NOT found within %d cases (unexpected)\n" cases
  | Tape_engine.Failed { minimal; original; attempts; _ } ->
    printf "  tape: found min_int; minimal = %Ld, original = %Ld, shrink attempts = %d\n"
      minimal original attempts);
  printf "\n";

  printf "=== 3. Generation-path performance cost ===\n";
  let n_timing = 500_000 in
  time_draws ~label:"no tape (plain uniform)" ~n:n_timing ~f:time_no_tape;
  time_draws ~label:"tape recording (this build)" ~n:n_timing ~f:time_tape_recording;
  printf "\n"

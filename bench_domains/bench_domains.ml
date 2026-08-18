(* Wall-clock scaling of the domain pool, as a primary results file.

   Written because README claimed "on a rare-failure workload with a
   ~100us test body the pool is a 4.6x wall-clock win at 8-16 domains"
   and that number traced only to a blog draft -- no benchmark in the
   tree produced it, so nobody could check it or notice it going stale
   (issue #12, item 8).

   Two workloads, because they answer different questions:

   - NO-FAILURE. The property never fails, so the run evaluates exactly
     [count] cases whatever [~domains] is. Identical work at every
     setting, so the ratio is pure generate-phase parallelism with no
     confound. This is the controlled measurement.
   - RARE-FAILURE. The property fails on one value in a large range, so
     the run finds it late and then shrinks. Closer to the sentence in
     the README, but attempt counts legitimately differ across domain
     counts (the engine evaluates batches speculatively, and documents
     that), so its ratio mixes parallel speedup with a different amount
     of work. Reported, and labelled as such, rather than presented as
     the headline.

   The test body is a calibrated busy-loop, not a sleep: a sleeping body
   would show near-perfect scaling and measure nothing but the
   scheduler. *)
open Base

module G = Base_quickcheck.Generator

(* Iterations of the busy loop, set by [calibrate] so one call is about
   100us. Deliberately a ref rather than a constant: the right count
   depends on the machine, and hard-coding one would silently change
   what the benchmark measures when it moves. *)
let burn_iters = ref 1000

let busy () =
  let x = ref 0.0 in
  for i = 1 to !burn_iters do
    x := !x +. Float.sqrt (Float.of_int i)
  done;
  Stdlib.Sys.opaque_identity !x
;;

let wall f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  (Unix.gettimeofday () -. t0, r)
;;

let calibrate ~target_us =
  (* Bisect on the iteration count until one [busy ()] lands within 10%
     of the target. Averaged over 200 calls, because a single call at
     100us is well inside timer noise. *)
  let time_of iters =
    burn_iters := iters;
    ignore (busy () : float);
    let elapsed, () =
      wall (fun () ->
        for _ = 1 to 200 do
          ignore (busy () : float)
        done)
    in
    elapsed /. 200. *. 1e6
  in
  let rec grow iters = if Float.( < ) (time_of iters) target_us then grow (iters * 2) else iters in
  let hi = grow 64 in
  let rec bisect lo hi n =
    if n = 0 then (lo + hi) / 2
    else
      let mid = (lo + hi) / 2 in
      if Float.( < ) (time_of mid) target_us then bisect mid hi (n - 1) else bisect lo mid (n - 1)
  in
  let iters = bisect (hi / 2) hi 20 in
  burn_iters := iters;
  (iters, time_of iters)
;;

(* NO-FAILURE: every case passes, so every domain count does the same
   [count] evaluations. *)
let no_failure ~domains ~count =
  wall (fun () ->
    match
      Tape_engine.run
        (G.int_uniform_inclusive 0 1_000_000)
        ~test:(fun v ->
          ignore (busy () : float);
          v >= 0)
        ~seed:17 ~count ~size:10 ~domains
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed _ -> failwith "no_failure workload failed -- benchmark is invalid")
;;

(* SHRINK-HEAVY: fails almost immediately on a large input, so nearly all
   the work is in the shrink phase rather than the generate phase.

   This is the workload that distinguishes the two claims. Shrinking is
   far less parallel than generation -- its bisection passes are
   sequential by nature, and a pool can only speculate within one batch
   -- so the speedup here is the floor and the generate-dominated number
   is the ceiling. Quoting either alone as "the" parallel speedup would
   be picking a number rather than reporting one. *)
let shrink_heavy ~domains =
  wall (fun () ->
    match
      Tape_engine.run
        (G.list_with_length (G.int_uniform_inclusive 0 100_000) ~length:120)
        ~test:(fun l ->
          ignore (busy () : float);
          List.sum (module Int) l ~f:Fn.id < 500_000)
        ~seed:5 ~count:200 ~size:30 ~domains ~budget:6000
    with
    | Tape_engine.Passed _ -> failwith "shrink_heavy did not fail -- invalid"
    | Tape_engine.Failed { attempts; _ } -> attempts)
;;

(* RARE-FAILURE: one value in the range fails. *)
let rare_failure ~domains ~count =
  wall (fun () ->
    match
      Tape_engine.run
        (G.int_uniform_inclusive 0 20_000)
        ~test:(fun v ->
          ignore (busy () : float);
          v <> 19_997)
        ~seed:17 ~count ~size:10 ~domains
    with
    | Tape_engine.Passed _ -> `Passed
    | Tape_engine.Failed { attempts; _ } -> `Failed attempts)
;;

let median xs =
  let a = Array.of_list xs in
  Array.sort a ~compare:Float.compare;
  a.(Array.length a / 2)
;;

let () =
  let reps = 5 in
  let count = 20_000 in
  let cores = Stdlib.Domain.recommended_domain_count () in
  let iters, measured_us = calibrate ~target_us:100. in
  Stdio.printf "bench_domains\n";
  Stdio.printf "  recommended_domain_count = %d\n" cores;
  Stdio.printf "  busy loop: %d iterations = %.1f us per test body\n" iters measured_us;
  Stdio.printf "  %d generate-phase cases per run, median of %d runs\n\n" count reps;

  let settings = [ 1; 2; 4; 8; 16; 32 ] in

  Stdio.printf "NO-FAILURE (identical work at every setting)\n";
  Stdio.printf "  domains      wall s    speedup vs 1\n";
  let baseline = ref 0.0 in
  List.iter settings ~f:(fun domains ->
    let times =
      List.init reps ~f:(fun _ ->
        let t, () = no_failure ~domains ~count in
        t)
    in
    let t = median times in
    if domains = 1 then baseline := t;
    Stdio.printf "  %-11d  %7.3f    %5.2fx\n" domains t (!baseline /. t));

  Stdio.printf "\nRARE-FAILURE (attempt counts differ by design; see header)\n";
  Stdio.printf "  domains      wall s    speedup vs 1   attempts\n";
  let rbaseline = ref 0.0 in
  List.iter settings ~f:(fun domains ->
    let results = List.init reps ~f:(fun _ -> rare_failure ~domains ~count) in
    let times = List.map results ~f:fst in
    let t = median times in
    if domains = 1 then rbaseline := t;
    let attempts =
      match snd (List.hd_exn results) with `Failed a -> Int.to_string a | `Passed -> "none"
    in
    Stdio.printf "  %-11d  %7.3f    %5.2fx          %s\n" domains t (!rbaseline /. t) attempts);

  Stdio.printf "\nSHRINK-HEAVY (fails at once; nearly all work is shrinking)\n";
  Stdio.printf "  domains      wall s    speedup vs 1   attempts\n";
  let sbaseline = ref 0.0 in
  List.iter settings ~f:(fun domains ->
    let results = List.init reps ~f:(fun _ -> shrink_heavy ~domains) in
    let t = median (List.map results ~f:fst) in
    if domains = 1 then sbaseline := t;
    Stdio.printf "  %-11d  %7.3f    %5.2fx          %d\n" domains t
      (!sbaseline /. t)
      (snd (List.hd_exn results)));
  Stdio.printf "\n"
;;

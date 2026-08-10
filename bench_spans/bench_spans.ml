(* Measure ordinary, unattached list generation with and without an unused
   span bracket.  This is a randomised paired-block design: every block runs
   the same deterministic workload under both treatments, in random order.
   Report all paired observations and uncertainty; do not select the fastest
   repetition. *)
open! Base

module G = Base_quickcheck.Generator

type Splittable_random.span_label += Bench_element

let samples = 30_000
let blocks = 60

let list_with bracket elt_gen =
  G.bind (G.sizes ()) ~f:(fun sizes ->
    G.create (fun ~size:_ ~random ->
      List.map sizes ~f:(fun size ->
        bracket random (fun () -> G.generate elt_gen ~size ~random))))
;;

let no_span _random f = f ()

let with_span random f =
  Splittable_random.with_span random Bench_element ~f
;;

let run generator =
  let random = Splittable_random.of_int 42 in
  let total = ref 0 in
  for _ = 1 to samples do
    total := !total + List.length (G.generate generator ~size:30 ~random)
  done;
  !total
;;

let elapsed generator =
  Stdlib.Gc.full_major ();
  let started = Unix.gettimeofday () in
  let checksum = run generator in
  Unix.gettimeofday () -. started, checksum
;;

let mean xs = Array.sum (module Float) xs ~f:Fn.id /. Float.of_int (Array.length xs)

let sample_sd xs =
  let average = mean xs in
  let squares =
    Array.sum (module Float) xs ~f:(fun x -> (x -. average) **. 2.)
  in
  Float.sqrt (squares /. Float.of_int (Array.length xs - 1))
;;

let () =
  let elt = G.int_uniform_inclusive 0 1000 in
  let without = list_with no_span elt in
  let with_ = list_with with_span elt in
  (* Warm both code paths before collecting observations. *)
  ignore (run without : int);
  ignore (run with_ : int);
  let order_random = Splittable_random.of_int 0x5a17 in
  let without_times = Array.create ~len:blocks 0. in
  let with_times = Array.create ~len:blocks 0. in
  let without_first = Array.init blocks ~f:(fun i -> i < blocks / 2) in
  for i = blocks - 1 downto 1 do
    let j = Splittable_random.int order_random ~lo:0 ~hi:i in
    Array.swap without_first i j
  done;
  let checksum_without = ref 0 and checksum_with = ref 0 in
  for block = 0 to blocks - 1 do
    let measure_without () =
      let elapsed, checksum = elapsed without in
      without_times.(block) <- elapsed;
      checksum_without := checksum
    in
    let measure_with () =
      let elapsed, checksum = elapsed with_ in
      with_times.(block) <- elapsed;
      checksum_with := checksum
    in
    if without_first.(block)
    then (measure_without (); measure_with ())
    else (measure_with (); measure_without ())
  done;
  if !checksum_without <> !checksum_with
  then failwith "span benchmark treatments generated different workloads";
  let ns_per_element elapsed =
    elapsed *. 1e9 /. Float.of_int !checksum_without
  in
  let without_ns = Array.map without_times ~f:ns_per_element in
  let with_ns = Array.map with_times ~f:ns_per_element in
  let deltas = Array.map2_exn without_ns with_ns ~f:(fun a b -> b -. a) in
  let log_ratios =
    Array.map2_exn without_ns with_ns ~f:(fun a b -> Float.log (b /. a))
  in
  let average_without = mean without_ns in
  let average_with = mean with_ns in
  let average_delta = mean deltas in
  let average_log_ratio = mean log_ratios in
  let standard_error =
    sample_sd log_ratios /. Float.sqrt (Float.of_int blocks)
  in
  (* Student t critical value for 59 degrees of freedom. *)
  let margin_95 = 2.001 *. standard_error in
  let relative_effect = Float.exp average_log_ratio -. 1. in
  let effect_lo = Float.exp (average_log_ratio -. margin_95) -. 1. in
  let effect_hi = Float.exp (average_log_ratio +. margin_95) -. 1. in
  let by_order wanted =
    Array.filter_mapi log_ratios ~f:(fun i ratio ->
      if Bool.equal without_first.(i) wanted then Some ratio else None)
    |> mean
    |> Float.exp
    |> fun ratio -> ratio -. 1.
  in
  let without_first_effect = by_order true in
  let with_first_effect = by_order false in
  Stdio.printf
    "randomised paired blocks: %d blocks x %d lists/treatment\n\
     without %.3f ns/element; with %.3f\n\
     paired geometric effect %+.2f%%, 95%% t CI [%+.2f%%, %+.2f%%]\n\
     by order: without-first %+.2f%%, with-first %+.2f%%\n\
     mean absolute delta %+.3f ns/element (secondary)\n\
     checksum %d\n"
    blocks
    samples
    average_without
    average_with
    (100. *. relative_effect)
    (100. *. effect_lo)
    (100. *. effect_hi)
    (100. *. without_first_effect)
    (100. *. with_first_effect)
    average_delta
    !checksum_without
  ;
  Array.iteri deltas ~f:(fun block delta ->
    Stdio.printf
      "  block %02d (%s first): without %.3f, with %.3f, ratio %.5f\n"
      (block + 1)
      (if without_first.(block) then "without" else "with")
      without_ns.(block)
      with_ns.(block)
      ((delta +. without_ns.(block)) /. without_ns.(block)))
;;

(* Measure the incremental cost of the production no-record fast path for
   observational list spans on an attached tape.  Each randomised paired block
   runs identical generated cases with the callbacks either handled by the
   production tape hooks or replaced by no-ops. *)
open! Base

module G = Base_quickcheck.Generator

let blocks = 60
let practical_margin = 0.05

let mean xs =
  Array.sum (module Float) xs ~f:Fn.id /. Float.of_int (Array.length xs)
;;

let sample_sd xs =
  let average = mean xs in
  let squares =
    Array.sum (module Float) xs ~f:(fun x -> (x -. average) **. 2.)
  in
  Float.sqrt (squares /. Float.of_int (Array.length xs - 1))
;;

let cpu_time () =
  let t = Unix.times () in
  t.tms_utime +. t.tms_stime
;;

let attach ~production_callbacks random tape =
  let hooks = Splittable_random.For_tape.hooks tape Tape.root in
  let hooks =
    if production_callbacks
    then hooks
    else
      { hooks with
        on_span_start =
          (fun _ ~deletable:_ ~discardable:_ ~descendable:_ ~reorderable:_ -> ())
      ; on_span_stop =
          (fun ~deletable:_ ~discardable:_ ~descendable:_ ~reorderable:_ ~discarded:_ () -> ())
      }
  in
  Splittable_random.with_intercept random hooks
;;

let run ~production_callbacks ~length ~samples generator =
  let checksum = ref 0 in
  for seed = 0 to samples - 1 do
    let tape = Tape.create () in
    Tape.start_recording tape;
    let random =
      attach ~production_callbacks (Splittable_random.of_int (seed + 0x51a7)) tape
    in
    let values = G.generate generator ~size:length ~random in
    let output = Tape.finish tape in
    if not (Array.is_empty output.spans)
    then failwith "observational spans should not be retained";
    checksum :=
      !checksum
      + List.fold values ~init:0 ~f:( + )
      + Array.length output.choices
  done;
  !checksum
;;

let elapsed ~production_callbacks ~length ~samples generator =
  Stdlib.Gc.full_major ();
  let started = cpu_time () in
  let checksum = run ~production_callbacks ~length ~samples generator in
  cpu_time () -. started, checksum
;;

let () =
  let length = ref 30 in
  let samples = ref 3_000 in
  let specs =
    [ "--length", Stdlib.Arg.Set_int length, " fixed list length"
    ; "--samples", Stdlib.Arg.Set_int samples, " cases per treatment per block"
    ]
  in
  Stdlib.Arg.parse specs Fn.ignore "bench_span_recording [options]";
  if !length <= 0 || !samples <= 0 then failwith "length and samples must be positive";
  let generator =
    G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:!length
  in
  ignore (run ~production_callbacks:false ~length:!length ~samples:100 generator : int);
  ignore (run ~production_callbacks:true ~length:!length ~samples:100 generator : int);
  let order_random = Splittable_random.of_int 0x7a11 in
  let ignore_first = Array.init blocks ~f:(fun i -> i < blocks / 2) in
  for i = blocks - 1 downto 1 do
    let j = Splittable_random.int order_random ~lo:0 ~hi:i in
    Array.swap ignore_first i j
  done;
  let ignored_times = Array.create ~len:blocks 0. in
  let production_times = Array.create ~len:blocks 0. in
  let ignored_checksum = ref 0 and production_checksum = ref 0 in
  for block = 0 to blocks - 1 do
    let measure production_callbacks times checksum =
      let seconds, value =
        elapsed ~production_callbacks ~length:!length ~samples:!samples generator
      in
      times.(block) <- seconds;
      checksum := value
    in
    if ignore_first.(block)
    then begin
      measure false ignored_times ignored_checksum;
      measure true production_times production_checksum
    end
    else begin
      measure true production_times production_checksum;
      measure false ignored_times ignored_checksum
    end
  done;
  if !ignored_checksum <> !production_checksum
  then failwith "span benchmark treatments generated different workloads";
  let elements = Float.of_int (!samples * !length) in
  let ns_per_element seconds = seconds *. 1e9 /. elements in
  let ignored_ns = Array.map ignored_times ~f:ns_per_element in
  let production_ns = Array.map production_times ~f:ns_per_element in
  let log_ratios =
    Array.map2_exn ignored_ns production_ns ~f:(fun ignored production ->
      Float.log (production /. ignored))
  in
  let average_log_ratio = mean log_ratios in
  let standard_error = sample_sd log_ratios /. Float.sqrt (Float.of_int blocks) in
  (* Student t critical value for 59 degrees of freedom. *)
  let margin_95 = 2.001 *. standard_error in
  let relative_effect = Float.exp average_log_ratio -. 1. in
  let effect_lo = Float.exp (average_log_ratio -. margin_95) -. 1. in
  let effect_hi = Float.exp (average_log_ratio +. margin_95) -. 1. in
  Stdio.printf
    "attached observational callbacks: %d randomised paired blocks x %d cases, length %d\n\
     ignored %.3f ns/element; production %.3f\n\
     paired geometric effect %+.2f%%, 95%% t CI [%+.2f%%, %+.2f%%]\n\
     practical slowdown margin +%.1f%%: %s\n\
     checksum %d\n"
    blocks
    !samples
    !length
    (mean ignored_ns)
    (mean production_ns)
    (100. *. relative_effect)
    (100. *. effect_lo)
    (100. *. effect_hi)
    (100. *. practical_margin)
    (if Float.(effect_hi < practical_margin) then "excluded" else "not excluded")
    !ignored_checksum;
  Array.iteri log_ratios ~f:(fun block log_ratio ->
    Stdio.printf
      "  block %02d (%s first): ignored %.3f, production %.3f, ratio %.5f\n"
      (block + 1)
      (if ignore_first.(block) then "ignored" else "production")
      ignored_ns.(block)
      production_ns.(block)
      (Float.exp log_ratio))
;;

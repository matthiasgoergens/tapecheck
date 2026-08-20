open! Base
open Stdio

let draws = ref 3_000_000
let blocks = ref 10
let process_id = ref 0
let warmup_draws = 250_000

let options =
  [ "--draws", Stdlib.Arg.Set_int draws, " Draws in each timed arm"
  ; "--blocks", Stdlib.Arg.Set_int blocks, " Paired blocks for each draw kind"
  ; "--process-id", Stdlib.Arg.Set_int process_id, " Process identifier"
  ]
;;

let fail_usage message =
  eprintf "%s\n" message;
  Stdlib.Arg.usage options "bench_fast_select [OPTIONS]";
  Stdlib.exit 2
;;

let state () = Stdlib.Sys.opaque_identity (Sr_real.of_int 42)

let bool_loop ~draw count state =
  let acc = ref 0 in
  fun () ->
    for _ = 1 to count do
      if draw state then Int.incr acc
    done;
    !acc
;;

let int_loop ~draw count state =
  let acc = ref 0 in
  fun () ->
    for _ = 1 to count do
      acc := !acc lxor draw state ~lo:0 ~hi:1000
    done;
    !acc
;;

let float_loop ~draw count state =
  let acc = ref 0. in
  fun () ->
    for _ = 1 to count do
      acc := !acc +. draw state ~lo:0. ~hi:1.
    done;
    Float.to_int !acc
;;

let bool_direct count = bool_loop ~draw:Fast_backend.bool count (state ())

let bool_selected count =
  let state = state () in
  let direct = bool_loop ~draw:Fast_backend.bool count state in
  let observed =
    bool_loop
      ~draw:(fun state ->
        Sr_real.Intercept.run_bool state ~default:Fast_backend.bool)
      count
      state
  in
  fun () -> if Sr_real.Intercept.is_active state then observed () else direct ()
;;

let int_direct count = int_loop ~draw:Fast_backend.int count (state ())

let int_selected count =
  let state = state () in
  let direct = int_loop ~draw:Fast_backend.int count state in
  let observed =
    int_loop
      ~draw:(fun state ~lo ~hi ->
        Sr_real.Intercept.run_int state ~lo ~hi ~default:Fast_backend.int)
      count
      state
  in
  fun () -> if Sr_real.Intercept.is_active state then observed () else direct ()
;;

let float_direct count = float_loop ~draw:Fast_backend.float count (state ())

let float_selected count =
  let state = state () in
  let direct = float_loop ~draw:Fast_backend.float count state in
  let observed =
    float_loop
      ~draw:(fun state ~lo ~hi ->
        Sr_real.Intercept.run_float state ~lo ~hi ~default:Fast_backend.float)
      count
      state
  in
  fun () -> if Sr_real.Intercept.is_active state then observed () else direct ()
;;

type subject =
  { name : string
  ; selected : int -> unit -> int
  ; direct : int -> unit -> int
  }

let subjects =
  [| { name = "bool"; selected = bool_selected; direct = bool_direct }
   ; { name = "int_0_1000"; selected = int_selected; direct = int_direct }
   ; { name = "float_0_1"; selected = float_selected; direct = float_direct }
  |]
;;

let verify_pointwise_backend () =
  for seed = 0 to 99 do
    let reference = Sr_real.of_int seed in
    let fast = Sr_real.of_int seed in
    for draw = 0 to 299 do
      match Int.rem draw 3 with
      | 0 ->
        if Bool.(Sr_real.bool reference <> Fast_backend.bool fast)
        then failwith (Printf.sprintf "Boolean backend mismatch at seed %d" seed)
      | 1 ->
        let expected = Sr_real.int reference ~lo:0 ~hi:1000 in
        let actual = Fast_backend.int fast ~lo:0 ~hi:1000 in
        if expected <> actual
        then failwith (Printf.sprintf "integer backend mismatch at seed %d" seed)
      | _ ->
        let expected = Sr_real.float reference ~lo:0. ~hi:1. in
        let actual = Fast_backend.float fast ~lo:0. ~hi:1. in
        if not (Float.equal expected actual)
        then failwith (Printf.sprintf "float backend mismatch at seed %d" seed)
    done
  done
;;

let time_run make_run =
  Stdlib.Gc.full_major ();
  let run = make_run () in
  let counter = Mtime_clock.counter () in
  let acc = Stdlib.Sys.opaque_identity (run ()) in
  let seconds = Mtime_clock.count counter |> Mtime.Span.to_float_ns |> ( *. ) 1e-9 in
  seconds, acc
;;

let warmup subject =
  let selected_acc = subject.selected warmup_draws () in
  let direct_acc = subject.direct warmup_draws () in
  if selected_acc <> direct_acc
  then
    failwith
      (Printf.sprintf
         "warm-up accumulator mismatch for %s: selected=%d direct=%d"
         subject.name
         selected_acc
         direct_acc)
;;

let emit_row ~block ~position ~subject ~selected_first =
  let selected_seconds, selected_acc, direct_seconds, direct_acc =
    if selected_first
    then (
      let selected_seconds, selected_acc =
        time_run (fun () -> subject.selected !draws)
      in
      let direct_seconds, direct_acc = time_run (fun () -> subject.direct !draws) in
      selected_seconds, selected_acc, direct_seconds, direct_acc)
    else (
      let direct_seconds, direct_acc = time_run (fun () -> subject.direct !draws) in
      let selected_seconds, selected_acc =
        time_run (fun () -> subject.selected !draws)
      in
      selected_seconds, selected_acc, direct_seconds, direct_acc)
  in
  if selected_acc <> direct_acc
  then
    failwith
      (Printf.sprintf
         "accumulator mismatch for %s: selected=%d direct=%d"
         subject.name
         selected_acc
         direct_acc);
  printf
    "%d\t%d\t%d\t%s\t%s\t%d\t%.9f\t%.9f\t%d\t%d\n%!"
    !process_id
    block
    position
    subject.name
    (if selected_first then "seam_first" else "nohook_first")
    !draws
    direct_seconds
    selected_seconds
    direct_acc
    selected_acc
;;

let () =
  Stdlib.Arg.parse options ignore "bench_fast_select [OPTIONS]";
  if !draws <= 0 then fail_usage "--draws must be positive";
  if !blocks <= 0 || Int.rem !blocks 2 <> 0
  then fail_usage "--blocks must be a positive even number";
  verify_pointwise_backend ();
  Array.iter subjects ~f:warmup;
  printf "# benchmark=inactive_whole_generator_selection\n";
  printf "# ratio_alias=seam_over_nohook_means_selected_over_direct\n";
  printf "# pid=%d\n" (Unix.getpid ());
  printf "# warmup_draws=%d\n" warmup_draws;
  printf "# pointwise_control=100_seeds_x_300_mixed_draws_passed\n";
  printf
    "process_id\tblock\tposition\tdraw\torder\tdraws\tnohook_seconds\tseam_seconds\tnohook_acc\tseam_acc\n%!";
  for block = 0 to !blocks - 1 do
    for position = 0 to Array.length subjects - 1 do
      let index = Int.rem (!process_id + block + position) (Array.length subjects) in
      let subject = subjects.(index) in
      let selected_first = Int.rem (!process_id + block + index) 2 = 0 in
      emit_row ~block ~position ~subject ~selected_first
    done
  done
;;

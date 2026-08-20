(* Paired timing harness for the cost of an unused Intercept seam.

   The process is the experimental unit.  Within each process, draw kinds are
   rotated and seam/no-hook order is counterbalanced across short blocks.  See
   DESIGN.md for the predeclared analysis. *)

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
  Stdlib.Arg.usage options "bench_intercept [OPTIONS]";
  Stdlib.exit 2
;;

let bool_real count =
  let state = Sr_real.of_int 42 in
  let acc = ref 0 in
  fun () ->
    for _ = 1 to count do
      if Sr_real.bool state then Int.incr acc
    done;
    !acc
;;

let bool_nohook count =
  let state = Sr_nohook.of_int 42 in
  let acc = ref 0 in
  fun () ->
    for _ = 1 to count do
      if Sr_nohook.bool state then Int.incr acc
    done;
    !acc
;;

let int_real count =
  let state = Sr_real.of_int 42 in
  let acc = ref 0 in
  fun () ->
    for _ = 1 to count do
      acc := !acc lxor Sr_real.int state ~lo:0 ~hi:1000
    done;
    !acc
;;

let int_nohook count =
  let state = Sr_nohook.of_int 42 in
  let acc = ref 0 in
  fun () ->
    for _ = 1 to count do
      acc := !acc lxor Sr_nohook.int state ~lo:0 ~hi:1000
    done;
    !acc
;;

let float_real count =
  let state = Sr_real.of_int 42 in
  let acc = ref 0. in
  fun () ->
    for _ = 1 to count do
      acc := !acc +. Sr_real.float state ~lo:0. ~hi:1.
    done;
    Float.to_int !acc
;;

let float_nohook count =
  let state = Sr_nohook.of_int 42 in
  let acc = ref 0. in
  fun () ->
    for _ = 1 to count do
      acc := !acc +. Sr_nohook.float state ~lo:0. ~hi:1.
    done;
    Float.to_int !acc
;;

type subject =
  { name : string
  ; seam : int -> unit -> int
  ; nohook : int -> unit -> int
  }

let subjects =
  [| { name = "bool"; seam = bool_real; nohook = bool_nohook }
   ; { name = "int_0_1000"; seam = int_real; nohook = int_nohook }
   ; { name = "float_0_1"; seam = float_real; nohook = float_nohook }
  |]
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
  let seam_acc = subject.seam warmup_draws () in
  let nohook_acc = subject.nohook warmup_draws () in
  if seam_acc <> nohook_acc
  then
    failwith
      (Printf.sprintf
         "warm-up accumulator mismatch for %s: seam=%d nohook=%d"
         subject.name
         seam_acc
         nohook_acc)
;;

let emit_row ~block ~position ~subject ~seam_first =
  let seam_seconds, seam_acc, nohook_seconds, nohook_acc =
    if seam_first
    then (
      let seam_seconds, seam_acc = time_run (fun () -> subject.seam !draws) in
      let nohook_seconds, nohook_acc = time_run (fun () -> subject.nohook !draws) in
      seam_seconds, seam_acc, nohook_seconds, nohook_acc)
    else (
      let nohook_seconds, nohook_acc = time_run (fun () -> subject.nohook !draws) in
      let seam_seconds, seam_acc = time_run (fun () -> subject.seam !draws) in
      seam_seconds, seam_acc, nohook_seconds, nohook_acc)
  in
  if seam_acc <> nohook_acc
  then
    failwith
      (Printf.sprintf
         "accumulator mismatch for %s: seam=%d nohook=%d"
         subject.name
         seam_acc
         nohook_acc);
  printf
    "%d\t%d\t%d\t%s\t%s\t%d\t%.9f\t%.9f\t%d\t%d\n%!"
    !process_id
    block
    position
    subject.name
    (if seam_first then "seam_first" else "nohook_first")
    !draws
    nohook_seconds
    seam_seconds
    nohook_acc
    seam_acc
;;

let () =
  Stdlib.Arg.parse options ignore "bench_intercept [OPTIONS]";
  if !draws <= 0 then fail_usage "--draws must be positive";
  if !blocks <= 0 || Int.rem !blocks 2 <> 0
  then fail_usage "--blocks must be a positive even number";
  Array.iter subjects ~f:warmup;
  printf "# benchmark=unused_intercept_seam\n";
  printf "# pid=%d\n" (Unix.getpid ());
  printf "# warmup_draws=%d\n" warmup_draws;
  printf
    "process_id\tblock\tposition\tdraw\torder\tdraws\tnohook_seconds\tseam_seconds\tnohook_acc\tseam_acc\n%!";
  for block = 0 to !blocks - 1 do
    for position = 0 to Array.length subjects - 1 do
      let index = Int.rem (!process_id + block + position) (Array.length subjects) in
      let subject = subjects.(index) in
      let seam_first = Int.rem (!process_id + block + index) 2 = 0 in
      emit_row ~block ~position ~subject ~seam_first
    done
  done
;;

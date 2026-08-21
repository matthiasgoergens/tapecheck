(* One-arm runner for the predeclared inactive-seam bound experiment.

   Each invocation measures one implementation and draw kind.  The shell
   harness randomises and pairs separate invocations, and optionally wraps
   them in [perf stat]. *)

open! Base
open Stdio

let implementation = ref ""
let draw = ref ""
let draws = ref 10_000_000
let seed = ref 42
let warmup_draws = 500_000

let options =
  [ "--implementation", Stdlib.Arg.Set_string implementation, " seam|direct|nohook|active"
  ; "--draw", Stdlib.Arg.Set_string draw, " bool|int_0_1000|float_0_1"
  ; "--draws", Stdlib.Arg.Set_int draws, " Draws in the timed region"
  ; "--seed", Stdlib.Arg.Set_int seed, " PRNG seed"
  ]
;;

let fail_usage message =
  eprintf "%s\n" message;
  Stdlib.Arg.usage options "bench_intercept_arm [OPTIONS]";
  Stdlib.exit 2
;;

let make_run ~count =
  match !implementation, !draw with
  | "seam", "bool" ->
    let state = Sr_real.of_int !seed in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        if Sr_real.bool state then Int.incr acc
      done;
      !acc
  | "direct", "bool" ->
    let state = Sr_real.of_int !seed in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        if Sr_real.For_benchmark.bool_direct state then Int.incr acc
      done;
      !acc
  | "nohook", "bool" ->
    let state = Sr_nohook.of_int !seed in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        if Sr_nohook.bool state then Int.incr acc
      done;
      !acc
  | "active", "bool" ->
    let state =
      Sr_real.with_intercept (Sr_real.of_int !seed) (Sr_real.Intercept.create ())
    in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        if Sr_real.bool state then Int.incr acc
      done;
      !acc
  | "seam", "int_0_1000" ->
    let state = Sr_real.of_int !seed in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        acc := !acc lxor Sr_real.int state ~lo:0 ~hi:1000
      done;
      !acc
  | "direct", "int_0_1000" ->
    let state = Sr_real.of_int !seed in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        acc := !acc lxor Sr_real.For_benchmark.int_direct state ~lo:0 ~hi:1000
      done;
      !acc
  | "nohook", "int_0_1000" ->
    let state = Sr_nohook.of_int !seed in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        acc := !acc lxor Sr_nohook.int state ~lo:0 ~hi:1000
      done;
      !acc
  | "active", "int_0_1000" ->
    let state =
      Sr_real.with_intercept (Sr_real.of_int !seed) (Sr_real.Intercept.create ())
    in
    let acc = ref 0 in
    fun () ->
      for _ = 1 to count do
        acc := !acc lxor Sr_real.int state ~lo:0 ~hi:1000
      done;
      !acc
  | "seam", "float_0_1" ->
    let state = Sr_real.of_int !seed in
    let acc = ref 0. in
    fun () ->
      for _ = 1 to count do
        acc := !acc +. Sr_real.float state ~lo:0. ~hi:1.
      done;
      Float.to_int !acc
  | "direct", "float_0_1" ->
    let state = Sr_real.of_int !seed in
    let acc = ref 0. in
    fun () ->
      for _ = 1 to count do
        acc := !acc +. Sr_real.For_benchmark.float_direct state ~lo:0. ~hi:1.
      done;
      Float.to_int !acc
  | "nohook", "float_0_1" ->
    let state = Sr_nohook.of_int !seed in
    let acc = ref 0. in
    fun () ->
      for _ = 1 to count do
        acc := !acc +. Sr_nohook.float state ~lo:0. ~hi:1.
      done;
      Float.to_int !acc
  | "active", "float_0_1" ->
    let state =
      Sr_real.with_intercept (Sr_real.of_int !seed) (Sr_real.Intercept.create ())
    in
    let acc = ref 0. in
    fun () ->
      for _ = 1 to count do
        acc := !acc +. Sr_real.float state ~lo:0. ~hi:1.
      done;
      Float.to_int !acc
  | implementation, draw ->
    fail_usage (Printf.sprintf "unsupported arm: implementation=%s draw=%s" implementation draw)
;;

let run count =
  let f = make_run ~count in
  Stdlib.Sys.opaque_identity (f ())
;;

let () =
  Stdlib.Arg.parse options ignore "bench_intercept_arm [OPTIONS]";
  if !draws <= 0 then fail_usage "--draws must be positive";
  ignore (run warmup_draws : int);
  Stdlib.Gc.full_major ();
  let f = make_run ~count:!draws in
  let counter = Mtime_clock.counter () in
  let accumulator = Stdlib.Sys.opaque_identity (f ()) in
  let seconds = Mtime_clock.count counter |> Mtime.Span.to_float_ns |> ( *. ) 1e-9 in
  printf
    "implementation\tdraw\tdraws\tseed\tseconds\taccumulator\n%s\t%s\t%d\t%d\t%.9f\t%d\n%!"
    !implementation
    !draw
    !draws
    !seed
    seconds
    accumulator
;;

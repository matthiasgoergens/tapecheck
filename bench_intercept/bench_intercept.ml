(* Does the Intercept seam cost anything when it is NOT in use?

   [sr_nohook] is [sr_real] (splittable_random v0.17.0 + the proposed
   seam) with the seam mechanically stripped: the [intercept] field, the
   six [match state.intercept] sites, and the [Intercept] module. It is
   otherwise the same source, built the same way, so the only difference
   measured here is the seam itself.

   Each draw entry point costs one load of an immutable field plus one
   compare against [None]. The inner rejection loops ([next_int64],
   [between], [non_negative_up_to]) are not intercepted, so the branch is
   once per user-level draw, not per PRNG step.

   Reported: min-of-reps nanoseconds per draw for each, alternating the
   two to spread any thermal drift across both. *)

open! Base
open Stdio

let n = 20_000_000
let reps = 5

let time_it f =
  let t0 = Stdlib.Sys.time () in
  let acc = f () in
  let t1 = Stdlib.Sys.time () in
  (t1 -. t0, acc)
;;

(* Each benchmark returns an accumulator that is printed, so neither the
   draws nor the loop can be eliminated. *)

let bool_real () =
  let st = Sr_real.of_int 42 in
  let acc = ref 0 in
  for _ = 1 to n do
    if Sr_real.bool st then Int.incr acc
  done;
  !acc
;;

let bool_nohook () =
  let st = Sr_nohook.of_int 42 in
  let acc = ref 0 in
  for _ = 1 to n do
    if Sr_nohook.bool st then Int.incr acc
  done;
  !acc
;;

let int_real () =
  let st = Sr_real.of_int 42 in
  let acc = ref 0 in
  for _ = 1 to n do
    acc := !acc lxor Sr_real.int st ~lo:0 ~hi:1000
  done;
  !acc
;;

let int_nohook () =
  let st = Sr_nohook.of_int 42 in
  let acc = ref 0 in
  for _ = 1 to n do
    acc := !acc lxor Sr_nohook.int st ~lo:0 ~hi:1000
  done;
  !acc
;;

let float_real () =
  let st = Sr_real.of_int 42 in
  let acc = ref 0. in
  for _ = 1 to n do
    acc := !acc +. Sr_real.float st ~lo:0. ~hi:1.
  done;
  Float.to_int !acc
;;

let float_nohook () =
  let st = Sr_nohook.of_int 42 in
  let acc = ref 0. in
  for _ = 1 to n do
    acc := !acc +. Sr_nohook.float st ~lo:0. ~hi:1.
  done;
  Float.to_int !acc
;;

let bench name ~real ~nohook =
  let best_real = ref Float.infinity
  and best_nohook = ref Float.infinity in
  let acc_real = ref 0
  and acc_nohook = ref 0 in
  for _ = 1 to reps do
    let t, a = time_it real in
    if Float.( < ) t !best_real then best_real := t;
    acc_real := a;
    let t, a = time_it nohook in
    if Float.( < ) t !best_nohook then best_nohook := t;
    acc_nohook := a
  done;
  let ns t = t *. 1e9 /. Float.of_int n in
  let r = ns !best_real
  and h = ns !best_nohook in
  printf
    "  %-12s  %7.2f      %7.2f    %+6.2f  (%+5.1f%%)   [acc %d/%d]\n"
    name
    h
    r
    (r -. h)
    (100. *. (r -. h) /. h)
    !acc_nohook
    !acc_real
;;

let () =
  printf
    "Intercept seam overhead when unused (intercept = None)\n\
     %d draws x %d reps, min-of-reps, ns/draw\n\n"
    n
    reps;
  printf "  %-12s  %7s      %7s    %6s\n" "draw" "no-hook" "seam" "delta";
  bench "bool" ~real:bool_real ~nohook:bool_nohook;
  bench "int 0..1000" ~real:int_real ~nohook:int_nohook;
  bench "float 0..1" ~real:float_real ~nohook:float_nohook;
  printf "\n(accumulators printed to keep the loops live)\n"
;;

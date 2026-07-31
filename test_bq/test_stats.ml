(* RO6 (outreach/ro-roadmap.md): statistics/health-check tests. Exercises
   Tape_stats (assume/event) and Tape_health (the four ported checks)
   through Tape_engine.run directly, so counts are checked against a
   controlled test function rather than trusted to a printed report. *)

open! Base
module G = Base_quickcheck.Generator

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let ran_ok f = try Ok (f ()) with exn -> Error exn

(* Busy-wait a fixed wall-clock duration -- used to make GENERATION
   itself slow, without pulling in the unix library: Stdlib.Sys.time is
   process CPU time, and a spin loop genuinely burns CPU, so this moves
   the wall clock without any extra dependency. *)
let busy_wait secs =
  let t0 = Stdlib.Sys.time () in
  while Float.(Stdlib.Sys.time () -. t0 < secs) do
    ()
  done

let () =
  (* --- discard counts, no assume: every case valid, none discarded --- *)
  let stats = Tape_engine.no_stats () in
  let gen = G.int_uniform_inclusive 0 999 in
  (match Tape_engine.run gen ~test:(fun _ -> true) ~count:50 ~stats with
  | Tape_engine.Passed { cases = 50 } -> ()
  | _ -> failwith "expected a clean pass over 50 cases");
  check "no assume: 0 discarded" (stats.cases_invalid = 0);
  check "no assume: 50 valid" (stats.cases_valid = 50);

  (* --- discard counts, assume always false: every case discarded --- *)
  let stats2 = Tape_engine.no_stats () in
  let health2 = Tape_health.create () in
  (match
     Tape_engine.run gen
       ~test:(fun _ ->
         Tape_stats.assume false;
         true)
       ~count:80 ~stats:stats2 ~health:health2
       ~suppress_health_check:[ Tape_health.Filter_too_much ]
   with
  | Tape_engine.Passed { cases = 80 } -> ()
  | _ -> failwith "expected a clean pass (never valid, never failing)");
  check "assume false: 80 discarded" (stats2.cases_invalid = 80);
  check "assume false: 0 valid" (stats2.cases_valid = 0);

  (* --- events aggregate correctly --- *)
  let stats3 = Tape_engine.no_stats () in
  let n = 60 in
  (match
     Tape_engine.run gen
       ~test:(fun v ->
         Tape_stats.event "always";
         Tape_stats.event ~payload:(if v % 2 = 0 then "even" else "odd")
           "parity";
         true)
       ~count:n ~stats:stats3
   with
  | Tape_engine.Passed { cases } -> check "events: full count reached" (cases = n)
  | Tape_engine.Failed _ -> failwith "unexpected failure");
  check "events: 'always' seen once per case"
    (Hashtbl.find_exn stats3.events "always" = n);
  let even_n =
    Option.value (Hashtbl.find stats3.events "parity: even") ~default:0
  in
  let odd_n =
    Option.value (Hashtbl.find stats3.events "parity: odd") ~default:0
  in
  check "events: parity tags partition the cases" (even_n + odd_n = n);

  (* --- health check: filter_too_much fires when unsuppressed --- *)
  let stats4 = Tape_engine.no_stats () in
  let health4 = Tape_health.create () in
  (match
     ran_ok (fun () ->
       Tape_engine.run gen
         ~test:(fun _ ->
           Tape_stats.assume false;
           true)
         ~count:200 ~stats:stats4 ~health:health4)
   with
  | Error _ -> ()
  | Ok _ -> failwith "expected filter_too_much to raise");
  check "filter_too_much: recorded as fired"
    (List.mem health4.Tape_health.fired Tape_health.Filter_too_much
       ~equal:Tape_health.equal);

  (* --- health check: filter_too_much suppressed stays quiet, but the
     discard COUNT (the primary RO6 statistic, distinct from the health
     check) is still accurate and unaffected by suppression --- *)
  let stats5 = Tape_engine.no_stats () in
  let health5 = Tape_health.create () in
  (match
     ran_ok (fun () ->
       Tape_engine.run gen
         ~test:(fun _ ->
           Tape_stats.assume false;
           true)
         ~count:200 ~stats:stats5 ~health:health5
         ~suppress_health_check:[ Tape_health.Filter_too_much ])
   with
  | Ok (Tape_engine.Passed { cases = 200 }) -> ()
  | Ok _ -> failwith "expected a clean pass"
  | Error _ -> failwith "suppressed health check must not raise");
  check "filter_too_much suppressed: still recorded as fired"
    (List.mem health5.Tape_health.fired Tape_health.Filter_too_much
       ~equal:Tape_health.equal);
  check "filter_too_much suppressed: discard count still accurate"
    (stats5.cases_invalid = 200);

  (* --- health check: quiet on a well-behaved property --- *)
  let stats6 = Tape_engine.no_stats () in
  let health6 = Tape_health.create () in
  (match
     ran_ok (fun () ->
       Tape_engine.run gen ~test:(fun _ -> true) ~count:50 ~stats:stats6
         ~health:health6)
   with
  | Ok (Tape_engine.Passed _) -> ()
  | _ -> failwith "expected a clean, unremarkable pass");
  check "well-behaved: no health checks fired"
    (List.is_empty health6.Tape_health.fired);
  check "well-behaved: no discards" (stats6.cases_invalid = 0);

  (* --- health check: data_too_large fires on routinely large cases --- *)
  let big_list_gen =
    G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:600
  in
  let health7 = Tape_health.create () in
  (match
     ran_ok (fun () ->
       (* This generator's smallest natural example is ALSO large (a
          fixed-length list has no length choice to shrink away), so
          suppress large_base_example here to isolate data_too_large,
          which is what this test is about. *)
       Tape_engine.run big_list_gen ~test:(fun _ -> true) ~count:30
         ~health:health7
         ~suppress_health_check:[ Tape_health.Large_base_example ])
   with
  | Error _ -> ()
  | Ok _ -> failwith "expected data_too_large to raise");
  check "data_too_large: recorded as fired"
    (List.mem health7.Tape_health.fired Tape_health.Data_too_large
       ~equal:Tape_health.equal);

  (* --- health check: large_base_example fires when the smallest
     natural input is already big (a FIXED-length list has no length
     choice to shrink away, so its trivialized replay stays at the same
     length) --- *)
  let health8 = Tape_health.create () in
  (match
     ran_ok (fun () ->
       Tape_engine.run big_list_gen ~test:(fun _ -> true) ~count:1
         ~health:health8
         ~suppress_health_check:[ Tape_health.Data_too_large ])
   with
  | Error _ -> ()
  | Ok _ -> failwith "expected large_base_example to raise");
  check "large_base_example: recorded as fired"
    (List.mem health8.Tape_health.fired Tape_health.Large_base_example
       ~equal:Tape_health.equal);

  (* --- health check: large_base_example quiet on an ordinary small
     generator --- *)
  let health9 = Tape_health.create () in
  (match
     ran_ok (fun () ->
       Tape_engine.run gen ~test:(fun _ -> true) ~count:5 ~health:health9)
   with
  | Ok _ -> ()
  | Error _ -> failwith "small generator must not trip large_base_example");
  check "small generator: large_base_example did not fire"
    (not
       (List.mem health9.Tape_health.fired Tape_health.Large_base_example
          ~equal:Tape_health.equal));

  (* --- health check: too_slow fires when GENERATION (not the test
     body) is slow --- *)
  let slow_gen = G.map (G.int_uniform_inclusive 0 10) ~f:(fun v -> busy_wait 0.15; v) in
  let health10 = Tape_health.create () in
  (match
     ran_ok (fun () ->
       Tape_engine.run slow_gen ~test:(fun _ -> true) ~count:9 ~health:health10)
   with
  | Error _ -> ()
  | Ok _ -> failwith "expected too_slow to raise");
  check "too_slow: recorded as fired"
    (List.mem health10.Tape_health.fired Tape_health.Too_slow ~equal:Tape_health.equal);

  Stdlib.print_endline "all stats tests passed"

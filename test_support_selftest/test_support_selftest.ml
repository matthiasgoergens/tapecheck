(* Tests the test helpers.

   An assertion helper that can only ever say "ok" is worse than no
   helper: every test built on it is green and none of them checks
   anything. So each helper is exercised in BOTH directions here --
   it must accept the good case and reject the bad one.

   Same reasoning as validating a regression guard by reintroducing the
   bug it targets. The green direction is the cheap half. *)
open Base
module G = Base_quickcheck.Generator
module T = Test_support

(* Wide enough not to trip the engine's exhaustion warning, which is
   correct behaviour on a tiny range but pure noise here. *)
let small = G.int_uniform_inclusive 0 100_000

(* Run [f] with the shared failure counter isolated, and report whether
   it recorded a failure. This is how the reject direction is observed
   without failing this test. *)
let verdict f =
  let saved = !T.failures in
  T.failures := 0;
  T.silence := true;
  Exn.protect ~f ~finally:(fun () -> T.silence := false);
  let recorded = !T.failures in
  T.failures := saved;
  recorded > 0

let expect ~name ~want_rejected f =
  let rejected = verdict f in
  T.report name
    (Bool.equal rejected want_rejected)
    (Printf.sprintf "%s (wanted %s)"
       (if rejected then "rejected" else "accepted")
       (if want_rejected then "reject" else "accept"))

let () =
  Stdio.printf "find_any:\n";
  (* Never satisfiable on this range, so a failure is reachable from
     every seed. *)
  expect ~name:"accepts a reachable failure" ~want_rejected:false (fun () ->
    T.find_any ~name:"(inner)" ~gen:small ~test:(fun n -> n > 200_000) ());
  (* Always satisfiable: if find_any still says ok, it is not measuring
     anything. This is the direction that catches a broken helper. *)
  expect ~name:"rejects an unreachable failure" ~want_rejected:true (fun () ->
    T.find_any ~name:"(inner)" ~gen:small ~test:(fun _ -> true) ~runs:5 ());
  (* Between the two: a rate below the floor must be rejected, or the
     threshold is decorative. *)
  expect ~name:"rejects a rate below min_rate" ~want_rejected:true (fun () ->
    T.find_any ~name:"(inner)" ~gen:small ~test:(fun _ -> true) ~runs:5
      ~min_rate:50 ());

  Stdio.printf "assert_no_failure:\n";
  expect ~name:"accepts a true property" ~want_rejected:false (fun () ->
    T.assert_no_failure ~name:"(inner)" ~gen:small ~test:(fun _ -> true) ~runs:5 ());
  expect ~name:"rejects a falsifiable property" ~want_rejected:true (fun () ->
    T.assert_no_failure ~name:"(inner)" ~gen:small
      ~test:(fun n -> n > 200_000) ~runs:5 ());

  Stdio.printf "expect_raise:\n";
  expect ~name:"accepts a raising body" ~want_rejected:false (fun () ->
    T.expect_raise ~name:"(inner)" (fun () -> failwith "boom"));
  expect ~name:"rejects a silent body" ~want_rejected:true (fun () ->
    T.expect_raise ~name:"(inner)" (fun () -> ()));

  (* Hypothesis's scar, made executable: a setup that throws must NOT be
     mistaken for the expected failure. If setup ran inside the guarded
     region, this case would be reported as a pass and the body -- which
     never runs -- would never be checked at all. *)
  let body_ran = ref false in
  let setup_threw =
    try
      T.expect_raise ~name:"(inner)"
        ~setup:(fun () -> failwith "setup is broken")
        (fun () -> body_ran := true);
      false
    with _ -> true
  in
  T.report "setup failure is not the expected failure"
    (setup_threw && not !body_ran)
    (Printf.sprintf "setup propagated=%b body_ran=%b" setup_threw !body_ran);

  T.finish ~name:"test_support_selftest" ()

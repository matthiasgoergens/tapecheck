(* Issue #2: a property whose BODY collapses varied inputs to a single
   point produces a green run with a large case count, and nothing
   warns, because every existing health check looks at the GENERATED
   data -- which was fine. The reproducer in the issue generated
   diverse int lists and then built an empty Tape.image from every one
   of them, so 12 650 "images" were identical and the property was
   never tried on anything else.

   [?observe] labels the value handed to the property, so the engine
   can answer "did this run actually exercise anything?" without the
   test body changing. *)
open! Base
module G = Base_quickcheck.Generator

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let fired_trivial_only f =
  match f () with
  | _ -> false
  | exception e ->
    String.is_substring (Exn.to_string e) ~substring:"trivial_only"

let () =
  (* The issue's shape: varied input, collapsed observation. *)
  let collapsed () =
    Tape_engine.run ~seed:0 ~count:200
      (G.list (G.int_uniform_inclusive 0 1_000_000))
      ~observe:(fun _ -> "empty-image")
      ~test:(fun _ -> true)
  in
  check "collapsed observation fires trivial_only"
    (fired_trivial_only collapsed);

  (* Varied observation: silent. *)
  let varied () =
    Tape_engine.run ~seed:0 ~count:200
      (G.list (G.int_uniform_inclusive 0 1_000_000))
      ~observe:(fun l -> Int.to_string (List.length l))
      ~test:(fun _ -> true)
  in
  check "varied observation stays silent" (not (fired_trivial_only varied));

  (* No ?observe: silent, because no information is no warning. This is
     the honest limit the issue names -- the check only ever fires for
     someone who already asked a coverage question. *)
  let unlabelled () =
    Tape_engine.run ~seed:0 ~count:200
      (G.list (G.int_uniform_inclusive 0 1_000_000))
      ~test:(fun _ -> true)
  in
  check "no observe means no warning" (not (fired_trivial_only unlabelled));

  (* Suppressible, like every other check. *)
  let suppressed () =
    Tape_engine.run ~seed:0 ~count:200
      ~suppress_health_check:[ Tape_health.Trivial_only ]
      (G.list (G.int_uniform_inclusive 0 1_000_000))
      ~observe:(fun _ -> "empty-image")
      ~test:(fun _ -> true)
  in
  check "suppression silences it" (not (fired_trivial_only suppressed));

  (* Below the threshold a single bucket is a small sample, not
     evidence. *)
  let few () =
    Tape_engine.run ~seed:0 ~count:5
      (G.list (G.int_uniform_inclusive 0 1_000_000))
      ~observe:(fun _ -> "empty-image")
      ~test:(fun _ -> true)
  in
  check "a handful of cases is not enough to fire"
    (not (fired_trivial_only few));

  Stdio.printf "test_trivial_only: all assertions passed\n"

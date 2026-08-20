(* Milestone 2 acceptance: an UNMODIFIED [@@deriving quickcheck]
   generator records a tape and replays it to the identical value,
   with different underlying randomness. *)

open! Base
open Base_quickcheck.Export

type point =
  { x : int
  ; label : string
  ; ys : int list
  }
[@@deriving quickcheck, sexp_of, compare, equal]

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let generate_with ~tape ~seed =
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
  in
  Base_quickcheck.Generator.generate quickcheck_generator_point ~size:10
    ~random

let legacy_list_generic ?min_length ?max_length elt_gen =
  Base_quickcheck.Generator.bind
    (Base_quickcheck.Generator.sizes ?min_length ?max_length ())
    ~f:(fun sizes ->
      List.map sizes ~f:(fun size ->
        Base_quickcheck.Generator.with_size ~size elt_gen)
      |> Base_quickcheck.Generator.all)

let () =
  let tape = Tape.create () in

  (* Record a generation. *)
  Tape.start_recording tape;
  let v1 = generate_with ~tape ~seed:42 in
  let out1 = Tape.finish tape in
  check "recorded some choices" (Array.length out1.Tape.choices > 0);

  (* Replay it with a completely different seed: the tape, not the
     RNG, determines the value. *)
  Tape.start_replay tape out1.Tape.choices;
  let v2 = generate_with ~tape ~seed:12345 in
  let out2 = Tape.finish tape in
  check "replay reproduces the exact value" (equal_point v1 v2);
  check "replay is not overrun" (not out2.Tape.overrun);
  (* This asserts identity of the recording, not equality in the shrink
     preorder. Distinct choices can have the same distance from their targets
     and therefore compare equal under [compare_shortlex]. *)
  check "replay re-records the same tape"
    (Tape.equal_choices out1.Tape.choices out2.Tape.choices);

  (* Sanity: different seeds without a tape give different values
     (so the reproduction above is not vacuous). *)
  let fresh seed =
    let random = Splittable_random.of_int seed in
    Base_quickcheck.Generator.generate quickcheck_generator_point ~size:10
      ~random
  in
  check "different seeds differ untaped"
    (not (equal_point (fresh 42) (fresh 12345)));

  (* An untaped state records nothing. *)
  Tape.start_recording tape;
  let _ = fresh 42 in
  let out3 = Tape.finish tape in
  check "untaped states record nothing" (Array.length out3.Tape.choices = 0);

  (* Staged and foreign randomness backends may compute the same primitive
     draw without entering the ordinary [Splittable_random.int]/[bool]/[float]
     functions.  [Intercept.run_*] is their entry point: the hook-free path
     delegates directly, while an attached tape still records and replays the
     bounded draw.  This is the integration shape needed by AllegrOCaml's
     pointwise-equivalent C randomness backend. *)
  let backend_calls = ref 0 in
  let backend_int _ ~lo ~hi:_ =
    Int.incr backend_calls;
    lo
  in
  let plain_backend_state = Splittable_random.of_int 314 in
  check "plain backend state reports inactive interception"
    (not (Splittable_random.Intercept.is_active plain_backend_state));
  let plain_backend_value =
    Splittable_random.Intercept.run_int
      plain_backend_state
      ~lo:17
      ~hi:29
      ~default:backend_int
  in
  check "hook-free backend dispatch returns its default value"
    (plain_backend_value = 17);
  check "hook-free backend dispatch calls its default exactly once"
    (!backend_calls = 1);

  Tape.start_recording tape;
  let backend_state =
    Splittable_random.For_tape.attach (Splittable_random.of_int 2718) tape
  in
  check "attached backend state reports active interception"
    (Splittable_random.Intercept.is_active backend_state);
  let recorded_backend_bool =
    Splittable_random.Intercept.run_bool backend_state
      ~default:(fun _ -> false)
  in
  let recorded_backend_int =
    Splittable_random.Intercept.run_int backend_state ~lo:17 ~hi:29
      ~default:backend_int
  in
  let recorded_backend_float =
    Splittable_random.Intercept.run_float backend_state ~lo:0.25 ~hi:0.75
      ~default:(fun _ ~lo ~hi:_ -> lo)
  in
  let backend_recording = Tape.finish tape in
  check "backend dispatch records all three primitive choices"
    (Array.length backend_recording.Tape.choices = 3);

  Tape.start_replay tape backend_recording.Tape.choices;
  let replay_backend_state =
    Splittable_random.For_tape.attach (Splittable_random.of_int 1618) tape
  in
  let replay_default_calls = ref 0 in
  let unused default =
    Int.incr replay_default_calls;
    default
  in
  let replayed_backend_bool =
    Splittable_random.Intercept.run_bool replay_backend_state
      ~default:(fun _ -> unused true)
  in
  let replayed_backend_int =
    Splittable_random.Intercept.run_int replay_backend_state ~lo:17 ~hi:29
      ~default:(fun _ ~lo:_ ~hi:_ -> unused 29)
  in
  let replayed_backend_float =
    Splittable_random.Intercept.run_float replay_backend_state ~lo:0.25 ~hi:0.75
      ~default:(fun _ ~lo:_ ~hi:_ -> unused 0.75)
  in
  let replayed_backend = Tape.finish tape in
  check "backend replay ignores a different primitive implementation"
    (Bool.equal recorded_backend_bool replayed_backend_bool
     && Int.equal recorded_backend_int replayed_backend_int
     && Float.equal recorded_backend_float replayed_backend_float);
  check "backend replay did not call primitive defaults" (!replay_default_calls = 0);
  check "backend replay re-records the same choices"
    (Tape.equal_choices
       backend_recording.Tape.choices
       replayed_backend.Tape.choices);

  (* Weighted structural decisions retain their sampling law outside the tape,
     but are represented by a first-class Bool choice when attached.  Forced
     probabilities consume no randomness but remain forced tape nodes, matching
     Hypothesis's structural replay model. *)
  let random = Splittable_random.of_int 7 in
  check "probability zero is forced"
    (not (Splittable_random.bool_with_probability random ~probability:0.));
  check "probability one is forced"
    (Splittable_random.bool_with_probability random ~probability:1.);
  Tape.start_recording tape;
  let attached = Splittable_random.For_tape.attach random tape in
  check "attached probability zero is forced"
    (not (Splittable_random.bool_with_probability attached ~probability:0.));
  check "attached probability one is forced"
    (Splittable_random.bool_with_probability attached ~probability:1.);
  let forced = Tape.finish tape in
  check "forced probabilities remain on the tape"
    (Tape.equal_choices forced.Tape.choices
       [| Tape.Bool false; Tape.Bool true |]);
  Tape.start_replay tape [| Tape.Bool true |];
  let attached = Splittable_random.For_tape.attach random tape in
  check "forced replay cannot flip probability zero"
    (not (Splittable_random.bool_with_probability attached ~probability:0.));
  let forced_replay = Tape.finish tape in
  check "forced replay rewrites the constrained value"
    (Tape.equal_choices forced_replay.Tape.choices [| Tape.Bool false |]);
  Tape.start_recording tape;
  let attached = Splittable_random.For_tape.attach random tape in
  ignore
    (Splittable_random.bool_with_probability attached ~probability:0.75 : bool);
  let weighted = Tape.finish tape in
  check "weighted decision records one choice"
    (Array.length weighted.Tape.choices = 1);
  check "weighted decision records a bool"
    (match weighted.Tape.choices.(0) with
     | Tape.Bool _ -> true
     | Tape.Integer _ | Tape.Float _ | Tape.Marker -> false);
  Tape.start_replay tape [| Tape.Bool false |];
  let attached = Splittable_random.For_tape.attach random tape in
  let replayed =
    Splittable_random.bool_with_probability attached ~probability:0.75
  in
  let replayed_out = Tape.finish tape in
  check "weighted bool replay is editable" (not replayed);
  check "weighted bool replay does not overrun" (not replayed_out.Tape.overrun);
  Tape.start_replay tape [| Tape.Bool true |];
  let attached = Splittable_random.For_tape.attach random tape in
  let replayed =
    Splittable_random.bool_with_probability attached ~probability:0.25
  in
  let replayed_out = Tape.finish tape in
  check "weighted bool can replay true" replayed;
  check "weighted true replay does not overrun" (not replayed_out.Tape.overrun);

  (* Exercise the list combinator itself, not merely [with_span].  A fixed
     length avoids conflating element spans with the draws used to choose and
     allocate a variable length. *)
  let starts = ref 0 in
  let stops = ref 0 in
  let depth = ref 0 in
  let max_depth = ref 0 in
  let span_events = ref [] in
  let rec make_span_hooks () : Splittable_random.Intercept.t =
    Splittable_random.Intercept.create
      ~int64:
        (fun state ~lo ~hi ~default ->
          span_events := "draw" :: !span_events;
          default state ~lo ~hi)
      ~on_span_start:
        (fun _ ~deletable:_ ~discardable:_ ~descendable:_ ~reorderable:_ ->
          span_events := "start" :: !span_events;
          Int.incr starts;
          Int.incr depth;
          max_depth := Int.max !max_depth !depth)
      ~on_span_stop:
        (fun ~deletable:_ ~discardable:_ ~descendable:_ ~reorderable:_ ~discarded:_ () ->
          span_events := "stop" :: !span_events;
          check "list span stop has a matching start" (!depth > 0);
          Int.decr depth;
          Int.incr stops)
      ~on_split:(fun () -> Some (make_span_hooks ()))
      ~on_perturb:(fun _ -> Some (make_span_hooks ()))
      ()
  in
  let span_hooks = make_span_hooks () in
  let span_random =
    Splittable_random.with_intercept (Splittable_random.of_int 91) span_hooks
  in
  let spanned_values =
    Base_quickcheck.Generator.generate
      (Base_quickcheck.Generator.list_with_length
         (Base_quickcheck.Generator.int_uniform_inclusive 0 100)
         ~length:5)
      ~size:10
      ~random:span_random
  in
  check "fixed list generated five values" (List.length spanned_values = 5);
  check "list emits one span per element" (!starts = 5 && !stops = 5);
  check "list element spans are balanced" (!depth = 0);
  check "flat list element spans are not nested" (!max_depth = 1);
  let element_events =
    List.rev !span_events
    |> List.drop_while ~f:(fun event -> not (String.equal event "start"))
  in
  check "each element draw is inside its span"
    (List.equal
       String.equal
       element_events
       [ "start"; "draw"; "stop"
       ; "start"; "draw"; "stop"
       ; "start"; "draw"; "stop"
       ; "start"; "draw"; "stop"
       ; "start"; "draw"; "stop"
       ]);

  (* The unused span bracket must not change values or consume randomness.
     Compare with the exact pre-span [list_generic] definition. *)
  let compare_list_generators ~name current legacy =
    List.iter [ 0; 1; 10; 30 ] ~f:(fun size ->
      for seed = 0 to 249 do
        let generate generator =
          Base_quickcheck.Generator.generate
            generator
            ~size
            ~random:(Splittable_random.of_int seed)
        in
        check name (List.equal Int.equal (generate current) (generate legacy))
      done)
  in
  let int_gen = Base_quickcheck.Generator.int_uniform_inclusive (-100) 100 in
  compare_list_generators
    ~name:"list spans preserve default same-seed generation"
    (Base_quickcheck.Generator.list int_gen)
    (legacy_list_generic int_gen);
  compare_list_generators
    ~name:"list spans preserve bounded same-seed generation"
    (Base_quickcheck.Generator.list_with_length int_gen ~length:5)
    (legacy_list_generic int_gen ~min_length:5 ~max_length:5);

  Stdlib.print_endline "test_roundtrip: all passed";
  Stdlib.Printf.printf "tape length for one point: %d choices\n"
    (Array.length out1.Tape.choices);
  Stdlib.Printf.printf "sample value: %s\n"
    (Sexp.to_string_hum (sexp_of_point v1))

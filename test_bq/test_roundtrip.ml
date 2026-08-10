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

  (* Weighted structural decisions retain their sampling law outside the tape,
     but are represented by a first-class Bool choice when attached.  Forced
     probabilities consume no randomness and need no tape entry. *)
  let random = Splittable_random.of_int 7 in
  check "probability zero is forced"
    (not (Splittable_random.bool_with_probability random ~probability:0.));
  check "probability one is forced"
    (Splittable_random.bool_with_probability random ~probability:1.);
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

  Stdlib.print_endline "test_roundtrip: all passed";
  Stdlib.Printf.printf "tape length for one point: %d choices\n"
    (Array.length out1.Tape.choices);
  Stdlib.Printf.printf "sample value: %s\n"
    (Sexp.to_string_hum (sexp_of_point v1))

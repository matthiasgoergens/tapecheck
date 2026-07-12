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
    Splittable_random.For_tape.attach (Splittable_random.of_int seed)
  in
  Splittable_random.For_tape.set_tape (Some tape);
  let value =
    Base_quickcheck.Generator.generate quickcheck_generator_point ~size:10
      ~random
  in
  Splittable_random.For_tape.set_tape None;
  value

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
  check "replay re-records the same tape"
    (Tape.compare_shortlex out1.Tape.choices out2.Tape.choices = 0);

  (* Sanity: different seeds without a tape give different values
     (so the reproduction above is not vacuous). *)
  let fresh seed =
    let random = Splittable_random.of_int seed in
    Base_quickcheck.Generator.generate quickcheck_generator_point ~size:10
      ~random
  in
  check "different seeds differ untaped"
    (not (equal_point (fresh 42) (fresh 12345)));

  (* An untaped state ignores the tape entirely. *)
  Tape.start_recording tape;
  Splittable_random.For_tape.set_tape (Some tape);
  let _ = fresh 42 in
  Splittable_random.For_tape.set_tape None;
  let out3 = Tape.finish tape in
  check "untaped states record nothing" (Array.length out3.Tape.choices = 0);

  Stdlib.print_endline "all round-trip tests passed";
  Stdlib.Printf.printf "tape length for one point: %d choices\n"
    (Array.length out1.Tape.choices);
  Stdlib.Printf.printf "sample value: %s\n"
    (Sexp.to_string_hum (sexp_of_point v1))

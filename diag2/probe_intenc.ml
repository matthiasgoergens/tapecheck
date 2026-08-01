(* Why does shrinking settle on max_int? The challenge suite's answers
   are littered with 4611686018427387903 where Hypothesis reports 1. *)
open Base
module G = Base_quickcheck.Generator

let describe (c : Tape.choice) =
  match c with
  | Tape.Integer { value; lo; hi } -> Printf.sprintf "Int %Ld [%Ld,%Ld]" value lo hi
  | Tape.Float { value; _ } -> Printf.sprintf "Float %f" value
  | Tape.Bool b -> Printf.sprintf "Bool %b" b
  | Tape.Marker -> "Marker"

let record gen seed size =
  let tape = Tape.create () in
  Tape.start_recording tape;
  let random = Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape in
  let v = Base_quickcheck.Generator.generate gen ~size ~random in
  let out = Tape.finish tape in
  (v, out.Tape.image.Tape.main)

let () =
  Stdio.printf "G.int at size 30, first 12 seeds:\n";
  for seed = 0 to 11 do
    let v, m = record G.int seed 30 in
    Stdio.printf "  %22d  <- %s\n" v
      (String.concat ~sep:"; " (Array.to_list (Array.map m ~f:describe)))
  done;
  Stdio.printf "\nmax_int = %d\n" Int.max_value;
  (* What does the all-minimal tape produce? That is what shrinking
     drives towards, so it should be 0. *)
  Stdio.printf "\nReplaying a tape of all-minimal choices:\n";
  let _, m = record G.int 0 30 in
  let minimal =
    Array.map m ~f:(function
      | Tape.Integer { lo; hi; _ } -> Tape.Integer { value = lo; lo; hi }
      | c -> c)
  in
  let tape = Tape.create () in
  Tape.start_replay_image tape { Tape.main = minimal; streams = [||] };
  let random = Splittable_random.For_tape.attach (Splittable_random.of_int 0) tape in
  let v = Base_quickcheck.Generator.generate G.int ~size:30 ~random in
  ignore (Tape.finish tape : Tape.output);
  Stdio.printf "  all-lo tape -> %d\n" v

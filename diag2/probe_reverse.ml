(* The reverse challenge settles on [0, max_int] rather than [0, 1].
   Which choice is stuck, and why? *)
open Base
module G = Base_quickcheck.Generator

let describe (c : Tape.choice) =
  match c with
  | Tape.Integer { value; lo; hi } -> Printf.sprintf "Int %Ld [%Ld,%Ld]" value lo hi
  | Tape.Float { value; _ } -> Printf.sprintf "Float %.6f" value
  | Tape.Bool b -> Printf.sprintf "Bool %b" b
  | Tape.Marker -> "M"

let show l = "[" ^ String.concat ~sep:"; " (List.map l ~f:Int.to_string) ^ "]"

let () =
  let gen = G.list G.int in
  let test l = List.equal Int.equal (List.rev l) l in
  for t = 0 to 3 do
    match Tape_engine.run gen ~test ~seed:(t * 7919) ~count:500 ~size:30 ~budget:20_000 with
    | Tape_engine.Passed _ -> Stdio.printf "seed %d: passed\n" t
    | Tape_engine.Failed { minimal; image; attempts; converged; _ } ->
      Stdio.printf "seed %d: %s  (attempts %d, converged %b)\n" t (show minimal)
        attempts converged;
      Stdio.printf "   tape: %s\n\n"
        (String.concat ~sep:"; "
           (Array.to_list (Array.map image.Tape.main ~f:describe)))
  done;
  (* And directly: is [0;1] even reachable, and is its tape smaller? *)
  Stdio.printf "For comparison, recording the value [0; 1] is not something we\n\
               \ can ask for directly; instead check what the engine thinks of\n\
               \ a hand-built two-element list.\n"

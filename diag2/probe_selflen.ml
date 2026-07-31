(* What does the tape look like for a stuck self_len case, and what
   single joint edit would escape it? *)
open Base
module G = Base_quickcheck.Generator

let show_choice (c : Tape.choice) =
  match c with
  | Tape.Integer { value; lo; hi } ->
    Printf.sprintf "I(%Ld in [%Ld,%Ld])" value lo hi
  | Tape.Float { value; _ } -> Printf.sprintf "F(%f)" value
  | Tape.Bool b -> Printf.sprintf "B(%b)" b
  | Tape.Marker -> "M"

let () =
  let gen = G.list (G.int_uniform_inclusive 0 50) in
  let test l =
    not (match l with [] -> false | h :: _ -> h = List.length l)
  in
  let shown = ref 0 in
  let t = ref 0 in
  while !shown < 2 && !t < 200 do
    (match Tape_engine.run gen ~test ~seed:(!t * 1_000_003) ~count:200 ~size:10 with
     | Tape_engine.Passed _ -> ()
     | Tape_engine.Failed { minimal; image; converged; _ } ->
       if not (List.equal Int.equal minimal [ 1 ]) then begin
         Int.incr shown;
         Stdio.printf "seed %d: stuck at %s (converged=%b)\n"
           (!t * 1_000_003)
           (Sexp.to_string ([%sexp_of: int list] minimal))
           converged;
         Stdio.printf "  main choices (%d): %s\n"
           (Array.length image.Tape.main)
           (String.concat ~sep:" "
              (Array.to_list (Array.map image.Tape.main ~f:show_choice)));
         Array.iter image.Tape.streams ~f:(fun (_, cs) ->
           Stdio.printf "  stream (%d): %s\n" (Array.length cs)
             (String.concat ~sep:" "
                (Array.to_list (Array.map cs ~f:show_choice))))
       end);
    Int.incr t
  done

open! Base
open Stdio
module G = Base_quickcheck.Generator

let show = function
  | Tape.Integer { value; lo; hi } ->
    Printf.sprintf "Int(%Ld in [%Ld,%Ld])" value lo hi
  | Tape.Float { value; lo; hi } ->
    Printf.sprintf "Float(%g in [%g,%g])" value lo hi
  | Tape.Bool b -> Printf.sprintf "Bool(%b)" b
  | Tape.Marker -> "Marker"

let () =
  let length_prefixed =
    let open G.Let_syntax in
    let%bind len = G.int_uniform_inclusive 1 64 in
    G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len
  in
  match
    Tape_engine.run length_prefixed ~test:(fun l ->
      List.sum (module Int) l ~f:Fn.id < 100)
  with
  | Tape_engine.Passed _ -> printf "passed?!\n"
  | Tape_engine.Failed { minimal; choices; attempts; _ } ->
    printf "minimal=%s attempts=%d\ntape (%d choices):\n"
      (Sexp.to_string ([%sexp_of: int list] minimal))
      attempts (Array.length choices);
    Array.iteri choices ~f:(fun i c -> printf "  %d: %s\n" i (show c))

(* Milestone 3 acceptance: the tape engine shrinks through the two
   shapes base_quickcheck's Shrinker.t model cannot handle at all for
   ad-hoc generators (whose default shrinker is atomic): filtered
   domains and monadic bind. *)

open! Base
module G = Base_quickcheck.Generator

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let () =
  (* Filtered domain: even ints, fail iff >= 100. The minimal failing
     even integer is exactly 100; a value shrinker cannot step over the
     filter, the tape re-vets every proposal through the generator.
     Uniform draws here: int_inclusive's weighted union routes 10% of
     draws through constant branches (return lo / return hi), whose
     one-choice tapes trap shortlex shrinking; see the design doc's
     "generator-structural bias" note. *)
  let even =
    G.filter (G.int_uniform_inclusive 0 100_000) ~f:(fun v -> v % 2 = 0)
  in
  let result =
    Tape_engine.run even ~test:(fun v -> v < 100)
  in
  (match result with
  | Tape_engine.Passed _ -> failwith "no failure found: filter"
  | Tape_engine.Failed { minimal; attempts; _ } ->
    Stdlib.Printf.printf "filter/even:   minimal=%d (%d attempts)\n" minimal
      attempts;
    check "filter shrinks to exactly 100" (minimal = 100));

  (* Length-prefixed list through bind: fail iff sum >= 100. Minimal
     is [100]: reaching it requires lowering the length choice while
     deleting an element choice, the lower-and-delete pass. *)
  let length_prefixed =
    let open G.Let_syntax in
    let%bind len = G.int_uniform_inclusive 1 64 in
    G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len
  in
  let result =
    Tape_engine.run length_prefixed ~test:(fun l ->
      List.sum (module Int) l ~f:Fn.id < 100)
  in
  (match result with
  | Tape_engine.Passed _ -> failwith "no failure found: bind"
  | Tape_engine.Failed { minimal; attempts; _ } ->
    Stdlib.Printf.printf "bind/sum:      minimal=%s (%d attempts)\n"
      (Sexp.to_string ([%sexp_of: int list] minimal))
      attempts;
    check "bind shrinks to [100]" (List.equal Int.equal minimal [ 100 ]));

  (* Chained binds: a >= b >= c by construction, fail always. The
     all-to-target pass lands on (10, 10, 10) immediately because
     replay keeps the dependencies intact. *)
  let chained =
    let open G.Let_syntax in
    let%bind a = G.int_uniform_inclusive 10 1000 in
    let%bind b = G.int_uniform_inclusive 10 a in
    let%map c = G.int_uniform_inclusive 10 b in
    (a, b, c)
  in
  let result = Tape_engine.run chained ~test:(fun _ -> false) in
  (match result with
  | Tape_engine.Passed _ -> failwith "no failure found: chained"
  | Tape_engine.Failed { minimal; attempts; _ } ->
    let a, b, c = minimal in
    Stdlib.Printf.printf "chained binds: minimal=(%d,%d,%d) (%d attempts)\n"
      a b c attempts;
    check "chained binds shrink to (10,10,10)"
      (a = 10 && b = 10 && c = 10));

  Stdlib.print_endline "all shrink tests passed"

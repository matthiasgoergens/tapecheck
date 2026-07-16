(* Stream-keyed tapes: generated functions shrink
   (design/stream-keyed-tapes.md).

   Generator.fn splits the random state at generation time and draws
   the result of each call from a copy perturbed with the argument's
   observed hash. With stream keys those draws are tape-controlled, so
   the engine can minimise WHAT THE FUNCTION RETURNS, and replay is
   stable: the same tape image regenerates a function with the same
   observed behaviour. *)

open! Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name cond =
  if not cond then begin
    Int.incr failures;
    Stdlib.Printf.printf "FAIL: %s\n" name
  end

(* A generated int -> int function, applied to a fixed argument. The
   property "f 0 < 100" fails for some functions; minimal counterexample
   is a function with f 0 = 100 and every other observed draw at
   target. *)
let () =
  let gen = G.fn (Base_quickcheck.Observer.int) (G.int_uniform_inclusive 0 1000) in
  match
    Tape_engine.run gen ~seed:0 ~count:300 ~size:10 ~budget:2000
      ~test:(fun f -> f 0 < 100)
  with
  | Tape_engine.Passed _ -> check "fn/point: found a failure" false
  | Tape_engine.Failed { minimal; image; attempts; _ } ->
    check "fn/point: minimal is exactly 100" (minimal 0 = 100);
    check "fn/point: tape carries streams" (Array.length image.Tape.streams > 0);
    (* Replay stability: regenerate from the winning image; the
       function must show the same behaviour at the probed point. *)
    let replayed, at0 =
      Tape_engine.replay_image_and_apply gen image ~f:(fun f -> f 0)
    in
    ignore replayed;
    check "fn/point: replayed function agrees" (at0 = 100);
    Stdlib.Printf.printf "fn/point:      minimal f(0)=%d (%d attempts)\n"
      (minimal 0) attempts

(* Function purity under shrinking: the test calls f twice on the same
   argument; a shrink edit must never produce a function that answers
   differently on the two calls (the call-boundary cursor rewind). *)
let () =
  let gen = G.fn (Base_quickcheck.Observer.int) (G.int_uniform_inclusive 0 1000) in
  match
    Tape_engine.run gen ~seed:1 ~count:300 ~size:10 ~budget:2000
      ~test:(fun f ->
        let a = f 7 and b = f 7 in
        a = b (* impurity would itself be the failure *) && a < 50)
  with
  | Tape_engine.Passed _ -> check "fn/pure: found a failure" false
  | Tape_engine.Failed { minimal; _ } ->
    check "fn/pure: same-arg calls agree on the minimal"
      (minimal 7 = minimal 7);
    check "fn/pure: minimal is the boundary" (minimal 7 = 50);
    Stdlib.Printf.printf "fn/pure:       minimal f(7)=%d\n" (minimal 7)

(* Function used across several arguments: the failing property looks
   at a sum of observed values, so several per-argument streams have to
   shrink together. *)
let () =
  let gen = G.fn (Base_quickcheck.Observer.int) (G.int_uniform_inclusive 0 1000) in
  match
    Tape_engine.run gen ~seed:2 ~count:300 ~size:10 ~budget:4000
      ~test:(fun f -> f 1 + f 2 < 100)
  with
  | Tape_engine.Passed _ -> check "fn/sum: found a failure" false
  | Tape_engine.Failed { minimal; attempts; _ } ->
    check "fn/sum: sum is minimal" (minimal 1 + minimal 2 = 100);
    Stdlib.Printf.printf "fn/sum:        minimal f(1)+f(2)=%d (%d attempts)\n"
      (minimal 1 + minimal 2)
      attempts

(* A pair of a list and a predicate: both the data and the function
   behaviour must shrink. Minimal shape: a single element on which the
   predicate answers true, with the element itself minimal. *)
let () =
  let gen =
    G.both
      (G.list_non_empty (G.int_uniform_inclusive 0 1000))
      (G.fn (Base_quickcheck.Observer.int) G.bool)
  in
  match
    Tape_engine.run gen ~seed:3 ~count:500 ~size:10 ~budget:4000
      ~test:(fun (xs, p) -> List.for_all xs ~f:(fun x -> not (p x)))
  with
  | Tape_engine.Passed _ -> check "fn/filter: found a failure" false
  | Tape_engine.Failed { minimal = xs, p; attempts; _ } ->
    check "fn/filter: single element" (List.length xs = 1);
    check "fn/filter: element is minimal"
      (match xs with [ x ] -> x = 0 | _ -> false);
    check "fn/filter: predicate holds on it"
      (match xs with [ x ] -> p x | _ -> false);
    Stdlib.Printf.printf "fn/filter:     minimal=(%s) (%d attempts)\n"
      (String.concat ~sep:";" (List.map xs ~f:Int.to_string))
      attempts

(* Serialization round-trip for stream-carrying images, plus v1 compat:
   a main-only image still serializes to the v1 format that pre-stream
   readers parse. *)
let () =
  let img : Tape.image =
    { main =
        [| Tape.Integer { value = 5L; lo = 0L; hi = 10L }; Tape.Marker |]
    ; streams =
        [| ( [ Tape.Split 0; Tape.Salt 12345 ]
           , [| Tape.Bool true
              ; Tape.Float { value = 0.5; lo = 0.; hi = 1. }
             |] )
         ; ([ Tape.Split 1 ], [| Tape.Integer { value = 7L; lo = 0L; hi = 9L } |])
        |]
    }
  in
  (match Tape.deserialize_image (Tape.serialize_image img) with
   | None -> check "serial/v2 round-trip parses" false
   | Some img' ->
     check "serial/v2 round-trip equal" (Tape.compare_image img img' = 0));
  let main_only = Tape.image_of_main img.Tape.main in
  let bytes = Tape.serialize_image main_only in
  check "serial/main-only emits v1" (Char.equal bytes.[0] '\001');
  (match Tape.deserialize bytes with
   | Some arr -> check "serial/v1 readable" (Tape.compare_shortlex arr img.Tape.main = 0)
   | None -> check "serial/v1 readable" false)

let () =
  if !failures = 0 then Stdlib.print_endline "all fn-shrink tests passed"
  else begin
    Stdlib.Printf.printf "%d fn-shrink test(s) FAILED\n" !failures;
    Stdlib.exit 1
  end

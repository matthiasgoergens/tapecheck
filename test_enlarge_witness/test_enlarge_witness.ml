(* Non-optimality by WITNESS, which scales where exhaustion does not.

   Take a failing tape T, enlarge it to T'' that still fails, and shrink
   T''. If the result is larger than T, the shrinker is provably
   non-optimal and T itself is the certificate: a smaller failing tape,
   exhibited. The stronger variant shrinks first -- T -> T' -- then
   enlarges T' and demands the result be no worse than EITHER.

   This can only ever certify non-optimality, never optimality, which
   is the same asymmetry a query point has for the skyline problem: a
   sampled x can refute a claimed skyline outright but confirms nothing
   beyond itself. test_exhaustive_oracle is the other side of that
   trade -- it decides optimality exactly, but only on 64 points.

   Enlargement has to preserve failure to be usable, so the properties
   here are UPWARD-CLOSED: raising a value never repairs them. That is
   a real restriction and it is why this is a witness rather than a
   measurement -- it says nothing about properties that fail only on a
   middle band. Failure is re-checked after enlarging anyway, since an
   upward-closed property in value space need not stay upward-closed
   through the tape encoding. *)
open! Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name cond detail =
  if not cond then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-44s %s\n" name detail
  end
  else Stdio.printf "  ok   %-44s %s\n" name detail

(* Raise choices toward their upper bound: shortlex-larger, same
   length, and for an upward-closed property still failing. *)
let enlarge (img : Tape.image) rnd =
  let bump (c : Tape.choice) =
    match c with
    | Tape.Integer { value; lo; hi } ->
      if Splittable_random.int rnd ~lo:0 ~hi:2 = 0 then c
      else begin
        let room = Int64.( - ) hi value in
        if Int64.( <= ) room 0L then c
        else
          let step =
            Int64.of_int (Splittable_random.int rnd ~lo:1 ~hi:64)
          in
          let step = if Int64.( > ) step room then room else step in
          Tape.Integer { value = Int64.( + ) value step; lo; hi }
      end
    | c -> c
  in
  { Tape.main = Array.map img.Tape.main ~f:bump
  ; streams = Array.map img.Tape.streams ~f:(fun (k, a) -> (k, Array.map a ~f:bump))
  }

let still_fails gen prop img =
  let tape = Tape.create () in
  Tape.start_replay_image tape img;
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int 99) tape
  in
  let v = G.generate gen ~size:12 ~random in
  let out = Tape.finish tape in
  (not out.Tape.overrun) && not (prop v)

let () =
  Stdio.printf "enlargement witnesses\n\n";
  let rnd = Splittable_random.of_int 31337 in
  let cases = ref 0 and worse_than_t = ref 0 and worse_than_t' = ref 0 in
  let enlargements = ref 0 in
  let subjects =
    [ ( "int, fails iff v >= 123457"
      , `Int (G.int_uniform_inclusive 0 1_000_000, fun v -> v < 123_457) )
    ; ( "list, fails iff sum >= 100"
      , `List
          ( G.list (G.int_uniform_inclusive 0 1000)
          , fun l -> List.sum (module Int) l ~f:Fn.id < 100 ) )
    ; ( "list, fails iff any element >= 900"
      , `List
          ( G.list (G.int_uniform_inclusive 0 1000)
          , fun l -> not (List.exists l ~f:(fun x -> x >= 900)) ) )
    ; ( "pair, fails iff a + b >= 100"
      , `Pair
          ( G.both (G.int_uniform_inclusive 0 1000)
              (G.int_uniform_inclusive 0 1000)
          , fun (a, b) -> a + b < 100 ) )
    ]
  in
  List.iter subjects ~f:(fun (name, subject) ->
    for seed = 0 to 149 do
      let run_and_witness (type a) (gen : a G.t) (prop : a -> bool) =
        match Tape_engine.run ~seed ~count:600 gen ~test:prop with
        | Tape_engine.Passed _ -> ()
        | Tape_engine.Failed { image = t_shrunk; _ } ->
          (* [image] is already the shrunk tape T'; enlarge it and
             demand the shrinker get back to something no larger. *)
          let big = enlarge t_shrunk rnd in
          if still_fails gen prop big && Tape.compare_image big t_shrunk > 0
          then begin
            Int.incr enlargements;
            Int.incr cases;
            match Tape_engine.resume gen ~test:prop big with
            | Tape_engine.Passed _ -> Int.incr worse_than_t'
            | Tape_engine.Failed { image = again; _ } ->
              if Tape.compare_image again t_shrunk > 0 then begin
                Int.incr worse_than_t';
                if !worse_than_t' <= 3 then
                  Stdio.printf
                    "    witness (%s, seed %d): re-shrunk %d choices vs %d\n"
                    name seed (Tape.image_size again) (Tape.image_size t_shrunk)
              end
          end
      in
      match subject with
      | `Int (g, p) -> run_and_witness g p
      | `List (g, p) -> run_and_witness g p
      | `Pair (g, p) -> run_and_witness g p
    done);
  check "re-shrinking an enlarged tape is no worse" (!worse_than_t' = 0)
    (Printf.sprintf "%d witnesses of non-optimality over %d enlargements"
       !worse_than_t' !cases);
  check "  ^ was not vacuous" (!enlargements > 20)
    (Printf.sprintf "%d enlargements actually grew the tape and still failed"
       !enlargements);
  ignore !worse_than_t;
  if !failures > 0 then begin
    Stdio.printf "\ntest_enlarge_witness: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_enlarge_witness: no non-optimality witnessed\n"

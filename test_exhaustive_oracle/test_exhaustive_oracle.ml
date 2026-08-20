(* A PARTIAL ORACLE for shrink quality: exact, but only on tiny inputs.

   CHALLENGE.md is explicit that [converged] does not mean "no smaller
   failing example exists", because establishing that needs exhaustive
   search over all smaller images. That is true in general and cheap in
   the small: over a generator drawing three ints from [0,3] the whole
   space is 64 tapes, so the true shortlex-minimal failing input can be
   computed by enumeration and compared against what the engine
   returns.

   Everything else here measures shrink quality as a RATE against a
   recorded threshold -- 21/48, 12/34, 47/100. This is the only check
   that knows the right answer.

   The properties are themselves generated: a random subset of the 64
   points is declared failing, which is the "generate the answer first"
   trick in its crudest form. Rather than invent a property and hope it
   discriminates, draw an arbitrary predicate; the oracle then tells us
   what the minimum is for that predicate. It also produces shapes no
   hand-written property would -- disconnected failing sets, failures
   only at the extremes, single-point failures. *)
open! Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name cond detail =
  if not cond then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-44s %s\n" name detail
  end
  else Stdio.printf "  ok   %-44s %s\n" name detail

let hi = 3
(* [int_uniform_inclusive], not [int_inclusive]: the latter routes
   through non_uniform's weighted union, so a value costs several
   choices and the tape space is not the value space. *)
let subject =
  G.both
    (G.int_uniform_inclusive 0 hi)
    (G.both (G.int_uniform_inclusive 0 hi) (G.int_uniform_inclusive 0 hi))

let all_points =
  List.concat_map (List.init (hi + 1) ~f:Fn.id) ~f:(fun a ->
    List.concat_map (List.init (hi + 1) ~f:Fn.id) ~f:(fun b ->
      List.map (List.init (hi + 1) ~f:Fn.id) ~f:(fun c -> (a, (b, c)))))

(* Built by ENUMERATION rather than assumption: replay every tape in
   the space, see which value comes out, and keep the shortlex-least
   tape that produces it. Constructing the tape for a value directly
   would bake in an assumption about the encoding, which is exactly
   what just went wrong -- the first version assumed one choice per
   int, and int_inclusive spends several. *)
let image_of_point =
  let tbl = Hashtbl.Poly.create () in
  let ints = List.init (hi + 1) ~f:Fn.id in
  List.iter ints ~f:(fun a ->
    List.iter ints ~f:(fun b ->
      List.iter ints ~f:(fun c ->
        let cell v =
          Tape.Integer
            { value = Int64.of_int v; lo = 0L; hi = Int64.of_int hi }
        in
        let tape = Tape.create () in
        Tape.start_replay tape [| cell a; cell b; cell c |];
        let random =
          Splittable_random.For_tape.attach (Splittable_random.of_int 1) tape
        in
        let v = G.generate subject ~size:5 ~random in
        let out = Tape.finish tape in
        if not out.Tape.overrun then
          Hashtbl.update tbl v ~f:(function
            | None -> out.Tape.choices
            | Some prev ->
              if Tape.compare_shortlex out.Tape.choices prev < 0 then
                out.Tape.choices
              else prev))));
  tbl

let () =
  Stdio.printf "exhaustive oracle (exact minima on a 64-point space)\n\n";
  let rnd = Splittable_random.of_int 20260820 in
  let disagreements = ref 0 in
  let compared = ref 0 in
  let no_failure = ref 0 in
  let engine_smaller = ref 0 and engine_larger = ref 0 and tied = ref 0 in
  for _trial = 0 to 199 do
    (* Draw an arbitrary failing set: each point fails with some
       probability, so the shapes vary from "almost everything fails"
       to a single point. *)
    let p = Splittable_random.int rnd ~lo:1 ~hi:9 in
    let failing = Hashtbl.Poly.create () in
    List.iter all_points ~f:(fun pt ->
      if Splittable_random.int rnd ~lo:0 ~hi:9 < p then
        Hashtbl.set failing ~key:pt ~data:());
    let prop pt = not (Hashtbl.mem failing pt) in
    (* The oracle: the shortlex-least tape among all failing points. *)
    let truth =
      List.filter all_points ~f:(fun pt ->
        Hashtbl.mem failing pt && Hashtbl.mem image_of_point pt)
      |> List.min_elt ~compare:(fun x y ->
        Tape.compare_shortlex
          (Hashtbl.find_exn image_of_point x)
          (Hashtbl.find_exn image_of_point y))
    in
    match truth with
    | None -> Int.incr no_failure
    | Some expected -> (
      match
        Tape_engine.run ~seed:7 ~count:4000 ~budget:20_000 subject ~test:prop
      with
      | Tape_engine.Passed _ ->
        (* The engine failed to find a failure that provably exists. *)
        Int.incr disagreements
      | Tape_engine.Failed { minimal; _ } ->
        Int.incr compared;
        if not (Poly.equal minimal expected) then begin
          Int.incr disagreements;
          let cmp =
            Tape.compare_shortlex
              (Hashtbl.find_exn image_of_point minimal)
              (Hashtbl.find_exn image_of_point expected)
          in
          if cmp < 0 then Int.incr engine_smaller
          else if cmp > 0 then Int.incr engine_larger
          else Int.incr tied
        end)
  done;
  Stdio.printf "  engine smaller than oracle: %d | larger: %d | tied: %d\n"
    !engine_smaller !engine_larger !tied;
  check "the oracle is never beaten (engine never smaller)"
    (!engine_smaller = 0)
    (Printf.sprintf "%d cases where the engine beat the oracle" !engine_smaller);
  (* NOT an equality assertion. The engine never promised global
     minimality -- every pass is a heuristic over a limited
     neighbourhood, and CHALLENGE.md says so. The first version of this
     test asserted equality and "failed" on 39 predicates where the
     engine was simply behaving as documented.

     What the oracle gives instead is the first EXACT optimality rate
     in this repo: everything else scores shrink quality against a
     recorded threshold, this knows the right answer. 161/200 optimal,
     deterministic (predicates from a fixed seed, engine at seed 7), so
     it is pinned two-sided like the other guards -- an improvement
     should be noticed and recorded, not silently absorbed. *)
  let optimal = !compared - !disagreements in
  check "optimality rate has not regressed" (optimal >= 161)
    (Printf.sprintf "%d/%d optimal" optimal !compared);
  check "optimality rate has not silently improved" (optimal <= 161)
    (Printf.sprintf "%d/%d optimal (recorded 161)" optimal !compared);
  check "  ^ was not vacuous" (!compared > 150)
    (Printf.sprintf "%d predicates had a failing point (%d had none)" !compared
       !no_failure);
  if !failures > 0 then begin
    Stdio.printf "\ntest_exhaustive_oracle: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_exhaustive_oracle: engine agrees with the oracle\n"

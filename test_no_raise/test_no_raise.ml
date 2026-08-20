(* The simplest property there is: feed it rubbish and check nothing
   unexpected escapes.

   In OCaml this bites in a different place than in Python. Exhaustive
   matching makes [Match_failure] rare, and most failure is returned as
   [option]/[result] rather than raised -- but [Array.sub] and friends
   raise [Invalid_argument] on out-of-range indices, and the [_exn]
   family ([List.hd_exn], [Option.value_exn], [List.for_all2_exn],
   [Hashtbl.find_exn]) raises on shapes the type system does not rule
   out. Every shrink pass slices arrays by recorded offsets, so that is
   precisely where an escaping exception would come from: a
   cross-model review found reorder_spans slicing by an unvalidated
   parent span, which would have raised OUTSIDE [attempt] and killed
   the whole run rather than failing one proposal.

   Two surfaces are worth the rubbish: the deserialiser, which is the
   only place untrusted bytes enter (regression files, pasted tapes),
   and replay/resume, which is where a corrupted or hand-edited image
   meets the passes. *)
open! Base
module G = Base_quickcheck.Generator

let failures = ref 0

let law name cond detail =
  if not cond then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-46s %s\n" name detail
  end
  else Stdio.printf "  ok   %-46s %s\n" name detail

let subject = G.both (G.list (G.int_inclusive (-500) 500)) (G.list G.string)

let recorded seed =
  let tape = Tape.create () in
  Tape.start_recording tape;
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
  in
  let (_ : _) = G.generate subject ~size:12 ~random in
  (Tape.finish tape).Tape.image

(* Corruptions are GENERATED, not a fixed list: a mutation program is
   drawn (which operators, how many, where), then interpreted. A fixed
   corpus only ever tests the mutations someone thought of, and stops
   finding anything the moment it passes once.

   This is mutational fuzzing in the AFL mould rather than the
   structure-aware generation tapecheck itself does -- seed corpus of
   real serialised tapes, byte-level operators, no notion of validity.
   That is the right shape for a PARSER, where the interesting inputs
   are the nearly-valid ones. What it still lacks to be AFL proper is
   coverage feedback to steer the operators and minimisation of any
   crasher it finds. *)
type op =
  | Truncate of int
  | Drop_prefix of int
  | Flip of int * char
  | Double
  | Splice of int * int
  | Insert of int * char

let op_gen =
  let open Base_quickcheck.Generator in
  union
    [ map (int_inclusive 0 100) ~f:(fun p -> Truncate p)
    ; map (int_inclusive 0 100) ~f:(fun p -> Drop_prefix p)
    ; map (both (int_inclusive 0 100) (char_print)) ~f:(fun (p, c) -> Flip (p, c))
    ; return Double
    ; map (both (int_inclusive 0 100) (int_inclusive 0 100)) ~f:(fun (a, b) ->
        Splice (a, b))
    ; map (both (int_inclusive 0 100) char_print) ~f:(fun (p, c) -> Insert (p, c))
    ]

(* Positions are drawn as percentages so they stay in range for any
   input length; an operator that fell off the end would just be a
   no-op and waste the draw. *)
let at s pct =
  let n = String.length s in
  if n = 0 then 0 else Int.min (n - 1) (n * pct / 101)

let apply_op s = function
  | Truncate pct -> String.sub s ~pos:0 ~len:(at s pct)
  | Drop_prefix pct ->
    let i = at s pct in
    String.sub s ~pos:i ~len:(String.length s - i)
  | Flip (pct, c) ->
    if String.is_empty s then s
    else begin
      let b = Bytes.of_string s in
      Bytes.set b (at s pct) c;
      Bytes.to_string b
    end
  | Double -> s ^ s
  | Splice (a, b) ->
    let i = at s a and j = at s b in
    let lo = Int.min i j and hi = Int.max i j in
    String.sub s ~pos:0 ~len:lo ^ String.sub s ~pos:hi ~len:(String.length s - hi)
  | Insert (pct, c) ->
    let i = at s pct in
    String.sub s ~pos:0 ~len:i ^ String.of_char c
    ^ String.sub s ~pos:i ~len:(String.length s - i)

let corruptions () =
  let out = ref [] in
  let program = G.list_with_length op_gen ~length:3 in
  for seed = 0 to 299 do
    let rnd = Splittable_random.of_int (seed * 7919) in
    let ops = G.generate program ~size:8 ~random:rnd in
    let base = Tape.serialize_image (recorded (seed % 60)) in
    out := base :: List.fold ops ~init:base ~f:apply_op :: !out;
    (* Pure noise too, as a control: it should mostly die at the first
       parse step, and if it does not, the mutations are not reaching
       any deeper than random bytes do. *)
    let len = Splittable_random.int rnd ~lo:0 ~hi:80 in
    out :=
      String.init len ~f:(fun _ ->
        Char.of_int_exn (Splittable_random.int rnd ~lo:0 ~hi:255))
      :: !out
  done;
  !out

let () =
  Stdio.printf "nothing unexpected escapes\n\n";
  let inputs = corruptions () in

  (* The deserialiser returns an option; it must never raise, whatever
     the bytes. *)
  let raised = ref 0 and accepted = ref 0 in
  List.iter inputs ~f:(fun s ->
    match Tape.deserialize_image s with
    | Some _ -> Int.incr accepted
    | None -> ()
    | exception _ -> Int.incr raised);
  law "deserialize_image never raises" (!raised = 0)
    (Printf.sprintf "%d raised of %d inputs" !raised (List.length inputs));
  law "  ^ was not vacuous" (!accepted > 100)
    (Printf.sprintf "%d inputs parsed to Some" !accepted);

  let raised_c = ref 0 in
  List.iter inputs ~f:(fun s ->
    match Tape.deserialize s with
    | Some _ | None -> ()
    | exception _ -> Int.incr raised_c);
  law "deserialize never raises" (!raised_c = 0)
    (Printf.sprintf "%d raised" !raised_c);

  (* Anything the deserialiser DID accept is a tape the engine can be
     handed. Replaying and resuming from it must not raise either --
     this is the surface where a corrupted image meets the shrink
     passes and their array slicing. *)
  let parsed =
    List.filter_map inputs ~f:(fun s -> Tape.deserialize_image s)
  in
  let prop (l, ss) = List.length l < 5 && List.length ss < 5 in
  let replay_raised = ref 0 and resume_raised = ref 0 in
  List.iter parsed ~f:(fun img ->
    (match
       let t = Tape.create () in
       Tape.start_replay_image t img;
       let r =
         Splittable_random.For_tape.attach (Splittable_random.of_int 7) t
       in
       let (_ : _) = G.generate subject ~size:12 ~random:r in
       ignore (Tape.finish t)
     with
     | () -> ()
     | exception _ -> Int.incr replay_raised);
    match Tape_engine.resume subject ~test:prop img with
    | Tape_engine.Passed _ | Tape_engine.Failed _ -> ()
    | exception _ -> Int.incr resume_raised);
  law "replaying a parsed image never raises" (!replay_raised = 0)
    (Printf.sprintf "%d raised of %d images" !replay_raised
       (List.length parsed));
  law "resume on a parsed image never raises" (!resume_raised = 0)
    (Printf.sprintf "%d raised of %d images" !resume_raised
       (List.length parsed));

  (* And the ordinary entry point, over property shapes that are
     awkward on purpose: always-failing, discarding almost everything,
     and raising from the test body. *)
  let escaped = ref 0 in
  let run_shapes =
    [ ("always fails", fun (_ : int list * string list) -> false)
    ; ("always passes", fun _ -> true)
    ; ("raises", fun _ -> failwith "boom")
    ; ("assumes almost everything away",
       fun (l, _) ->
         Tape_stats.assume (List.length l = 3);
         true)
    ]
  in
  (* Health checks RAISE by design here, following Hypothesis's
     fail_health_check rather than warning, so an over-filtered run
     legitimately throws unless suppressed. Suppressing them is what
     makes the remaining escapes unexpected -- the first draft of this
     property did not, and reported the engine's documented behaviour
     as a failure. *)
  let all_checks =
    [ Tape_health.Filter_too_much; Tape_health.Too_slow
    ; Tape_health.Data_too_large; Tape_health.Large_base_example
    ; Tape_health.Trivial_only ]
  in
  List.iter run_shapes ~f:(fun (name, prop) ->
    for seed = 0 to 9 do
      match
        Tape_engine.run ~seed ~count:60 ~suppress_health_check:all_checks
          subject ~test:prop
      with
      | Tape_engine.Passed _ | Tape_engine.Failed _ -> ()
      | exception Failure _ when String.equal name "raises" -> ()
      | exception e ->
        Int.incr escaped;
        if !escaped <= 3 then
          Stdio.printf "    (%s, seed %d) %s\n" name seed (Exn.to_string e)
    done);
  law "run lets nothing unexpected escape" (!escaped = 0)
    (Printf.sprintf "%d escaped" !escaped);

  (* The other half of that contract, pinned rather than assumed: an
     over-filtered run MUST raise when the check is not suppressed. A
     health check that quietly stopped firing would otherwise look
     exactly like a clean run. *)
  let fired = ref 0 in
  for seed = 0 to 9 do
    match
      Tape_engine.run ~seed ~count:60 subject
        ~test:(fun (l, _) ->
          Tape_stats.assume (List.length l = 3);
          true)
    with
    | Tape_engine.Passed _ | Tape_engine.Failed _ -> ()
    | exception _ -> Int.incr fired
  done;
  law "an over-filtered run raises unless suppressed" (!fired > 5)
    (Printf.sprintf "%d/10 seeds raised" !fired);

  if !failures > 0 then begin
    Stdio.printf "\ntest_no_raise: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_no_raise: nothing escaped\n"

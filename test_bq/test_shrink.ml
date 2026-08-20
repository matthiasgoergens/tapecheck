(* Milestone 3 acceptance: the tape engine shrinks through the two
   shapes base_quickcheck's Shrinker.t model cannot handle at all for
   ad-hoc generators (whose default shrinker is atomic): filtered
   domains and monadic bind. *)

open! Base
module G = Base_quickcheck.Generator

type Splittable_random.span_label +=
  | Continuation_element
  | Observed_element
  | Discarded_attempt

exception Retry_attempt

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

  (* Below-target ranges shrink too: target clamps to hi = -1, every
     draw sits BELOW it; the review found the passes skipped this side
     entirely (minimal = original, no shrinking at all). *)
  let negatives = G.int_uniform_inclusive (-1000) (-1) in
  (match Tape_engine.run negatives ~test:(fun v -> v > -500) with
  | Tape_engine.Passed _ -> failwith "no failure found: negatives"
  | Tape_engine.Failed { minimal; attempts; _ } ->
    Stdlib.Printf.printf "negatives:     minimal=%d (%d attempts)\n" minimal
      attempts;
    check "below-target range shrinks to the boundary" (minimal = -500));

  (* Full-range int64 draws: the shortlex key must not overflow; the
     trivial pass lands on the in-range target 0. *)
  let full_range =
    G.int64_uniform_inclusive Int64.min_value Int64.max_value
  in
  (match Tape_engine.run full_range ~test:(fun _ -> false) with
  | Tape_engine.Passed _ -> failwith "no failure found: full range"
  | Tape_engine.Failed { minimal; _ } ->
    check "full-range int64 shrinks to zero" (Int64.equal minimal 0L));

  (* A raising property must propagate, not hang, under a pool. *)
  (match
     Or_error.try_with (fun () ->
       Tape_engine.run (G.int_uniform_inclusive 0 100) ~domains:2
         ~test:(fun _ -> failwith "boom"))
   with
  | Error _ -> ()
  | Ok _ -> failwith "raising test did not propagate under domains=2");

  (* Shrink results are domains-invariant (lowest-index acceptance). *)
  let seq =
    match
      Tape_engine.run length_prefixed ~test:(fun l ->
        List.sum (module Int) l ~f:Fn.id < 100)
    with
    | Tape_engine.Failed { minimal; _ } -> minimal
    | Tape_engine.Passed _ -> failwith "no failure: seq arm"
  in
  let par =
    match
      Tape_engine.run length_prefixed ~domains:4 ~test:(fun l ->
        List.sum (module Int) l ~f:Fn.id < 100)
    with
    | Tape_engine.Failed { minimal; _ } -> minimal
    | Tape_engine.Passed _ -> failwith "no failure: par arm"
  in
  check "domains-invariant minimal" (List.equal Int.equal seq par);

  (* A continuation decision and the element it guards form one span.  The
     supplied tape encodes [1; 100]; deleting the first complete span must
     replay as [100], whereas deleting the bare element choice would leave a
     true continuation with no value and overrun. *)
  let continuation_values random draw_element =
    let rec loop remaining acc =
      let forced = if remaining = 0 then Some false else None in
      match
        Splittable_random.with_span ~deletable:true random
          Continuation_element ~f:(fun () ->
          if
            Splittable_random.bool_with_probability random ~probability:0.5
              ?forced
          then
            Some (draw_element random)
          else None)
      with
      | None -> List.rev acc
      | Some value -> loop (remaining - 1) (value :: acc)
    in
    loop 4 []
  in
  let continuation_list draw_element =
    G.create (fun ~size:_ ~random -> continuation_values random draw_element)
  in
  let continuation_int =
    continuation_list (fun random ->
      Splittable_random.int random ~lo:0 ~hi:1000)
  in
  let int value = Tape.Integer { value = Int64.of_int value; lo = 0L; hi = 1000L } in
  let continuation_image =
    Tape.image_of_main
      [| Tape.Bool true
       ; int 1
       ; Tape.Bool true
       ; int 100
       ; Tape.Bool false
      |]
  in
  (match
     Tape_engine.resume continuation_int continuation_image
       ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
  with
  | Tape_engine.Passed _ -> failwith "continuation tape stopped failing"
  | Tape_engine.Failed { minimal; _ } ->
    check "span deletion removes an irrelevant leading element"
      (List.equal Int.equal minimal [ 100 ]));
  let delete_span_attempts =
    List.Assoc.find_exn (Tape_engine.Diagnostics.last_pass_costs ()) ~equal:String.equal
      "delete_spans"
  in
  check "span deletion pass was exercised" (delete_span_attempts > 0);
  (* An observational child span is part of its enclosing deletable unit.  It
     must not make that unit look non-leaf and silently disable middle-element
     deletion for composite generators. *)
  let observed_continuation_int =
    continuation_list (fun random ->
      Splittable_random.with_span random Observed_element ~f:(fun () ->
        Splittable_random.int random ~lo:0 ~hi:1000))
  in
  (match
     Tape_engine.resume observed_continuation_int continuation_image
       ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
   with
   | Tape_engine.Passed _ ->
     failwith "observed continuation tape stopped failing"
   | Tape_engine.Failed { minimal; _ } ->
     check "observational child span does not block parent deletion"
       (List.equal Int.equal minimal [ 100 ]));
  let observed_delete_span_attempts =
    List.Assoc.find_exn (Tape_engine.Diagnostics.last_pass_costs ()) ~equal:String.equal
      "delete_spans"
  in
  check "observed parent span deletion pass was exercised"
    (observed_delete_span_attempts > 0);
  (* The same edit must work in a split/keyed stream, as used by generated
     functions, rather than accidentally assuming every span belongs to the
     main stream. *)
  let split_continuation_int =
    G.create (fun ~size:_ ~random ->
      let child = Splittable_random.split random in
      continuation_values child (fun child ->
        Splittable_random.int child ~lo:0 ~hi:1000))
  in
  let keyed_continuation_image : Tape.image =
    { main = [| Tape.Marker |]
    ; streams = [| [ Tape.Split 0 ], continuation_image.main |]
    }
  in
  (match
     Tape_engine.resume split_continuation_int keyed_continuation_image
       ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
   with
   | Tape_engine.Passed _ -> failwith "keyed continuation tape stopped failing"
   | Tape_engine.Failed { minimal; _ } ->
     check "span deletion edits a keyed stream"
       (List.equal Int.equal minimal [ 100 ]));
  let keyed_delete_span_attempts =
    List.Assoc.find_exn (Tape_engine.Diagnostics.last_pass_costs ()) ~equal:String.equal
      "delete_spans"
  in
  check "keyed span deletion pass was exercised" (keyed_delete_span_attempts > 0);
  (* A failed generator attempt consumed choices but produced no part of the
     returned value.  Its exceptional span should be removed as one discarded
     region before ordinary value shrinking. *)
  let retrying_int =
    G.create (fun ~size:_ ~random ->
      let rec attempt () =
        try
          Splittable_random.with_span ~discard_on_exception:true random
            Discarded_attempt ~f:(fun () ->
            let retry = Splittable_random.bool random in
            let value = Splittable_random.int random ~lo:0 ~hi:1000 in
            if retry then raise Retry_attempt else value)
        with
        | Retry_attempt -> attempt ()
      in
      attempt ())
  in
  let discarded_image =
    Tape.image_of_main
      [| Tape.Bool true; int 999; Tape.Bool false; int 100 |]
  in
  (match
     Tape_engine.resume retrying_int discarded_image ~test:(fun value -> value < 100)
   with
   | Tape_engine.Passed _ -> failwith "discarded-attempt tape stopped failing"
   | Tape_engine.Failed { minimal; image; _ } ->
     check "discarded attempt leaves the same failing value" (minimal = 100);
     check "discarded attempt choices are absent from the minimal tape"
       (Array.length image.Tape.main <= 2));
  let remove_discarded_attempts =
    List.Assoc.find_exn (Tape_engine.Diagnostics.last_pass_costs ()) ~equal:String.equal
      "remove_discarded"
  in
  check "remove_discarded pass was exercised" (remove_discarded_attempts > 0);
  (match
     Tape_engine.resume retrying_int discarded_image ~domains:2
       ~test:(fun value -> value < 100)
   with
   | Tape_engine.Passed _ ->
     failwith "pooled discarded-attempt tape stopped failing"
   | Tape_engine.Failed { minimal; image; _ } ->
     check "pooled remove_discarded preserves the failing value" (minimal = 100);
     check "pooled remove_discarded removes the dead region"
       (Array.length image.Tape.main <= 2));
  let pooled_remove_discarded_attempts =
    List.Assoc.find_exn (Tape_engine.Diagnostics.last_pass_costs ()) ~equal:String.equal
      "remove_discarded"
  in
  check "pooled run exercises remove_discarded"
    (pooled_remove_discarded_attempts > 0);
  (match
     Tape_engine.resume observed_continuation_int continuation_image ~domains:2
       ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
   with
   | Tape_engine.Passed _ ->
     failwith "pooled observed continuation tape stopped failing"
   | Tape_engine.Failed { minimal; _ } ->
     check "pooled shrinking preserves deletable span metadata"
       (List.equal Int.equal minimal [ 100 ]));
  let pooled_delete_span_attempts =
    List.Assoc.find_exn (Tape_engine.Diagnostics.last_pass_costs ()) ~equal:String.equal
      "delete_spans"
  in
  check "pooled run exercises span deletion" (pooled_delete_span_attempts > 0);
  let maximum_length_image =
    Tape.image_of_main
      [| Tape.Bool true
       ; int 1
       ; Tape.Bool true
       ; int 100
       ; Tape.Bool true
       ; int 0
       ; Tape.Bool true
       ; int 0
       ; Tape.Bool false
      |]
  in
  (match
     Tape_engine.resume continuation_int maximum_length_image
       ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
  with
  | Tape_engine.Passed _ -> failwith "maximum-length continuation tape stopped failing"
  | Tape_engine.Failed { minimal; _ } ->
    check "forced terminal stop permits deletion at maximum length"
      (List.equal Int.equal minimal [ 100 ]));

  (* A shape-changing generator: a bool tag selects (int,int) [sum
     test] vs (bool,int) [int test]. The canonical minimum lives in the
     B shape (its tag choice is smaller). Consume loses shrink progress
     crossing shapes; Both carries it, so Both must reach the B-shape
     minimum where Consume can stall in an A-shape. *)
  let shape_gen =
    let open G.Let_syntax in
    match%bind G.bool with
    | true ->
      let%map a = G.int_uniform_inclusive 0 1000
      and b = G.int_uniform_inclusive 0 1000 in
      `A (a, b)
    | false ->
      let%map flag = G.bool and c = G.int_uniform_inclusive 0 1000 in
      `B (flag, c)
  in
  let shape_test = function
    | `A (a, b) -> a + b < 100
    | `B (_, c) -> c < 100
  in
  let run_shape ~realign ~domains ~seed =
    match
      Tape_engine.run shape_gen ~test:shape_test ~realign ~domains ~seed
        ~count:300 ~size:12 ~budget:4000
    with
    | Tape_engine.Failed { minimal; _ } -> minimal
    | Tape_engine.Passed _ -> failwith "no failure: shape_gen"
  in
  (* Both is domains-invariant even when it does the second replay. *)
  List.iter [ 0; 7; 42 ] ~f:(fun seed ->
    let seq = run_shape ~realign:`Both ~domains:1 ~seed in
    let par = run_shape ~realign:`Both ~domains:4 ~seed in
    check "Both is domains-invariant"
      (Poly.equal seq par));

  (* Both reaches the canonical B-shape minimum on at least one seed
     where Consume stalls in an A-shape (proves the win is real, not
     just never-worse). *)
  let both_reached_b =
    List.exists [ 0; 1; 2; 3; 4; 5; 6; 7 ] ~f:(fun seed ->
      match run_shape ~realign:`Both ~domains:1 ~seed with
      | `B _ -> true
      | `A _ -> false)
  in
  check "Both reaches the B-shape minimum on some seed" both_reached_b;

  Stdlib.print_endline "test_shrink: all passed"

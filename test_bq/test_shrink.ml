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

  Stdlib.print_endline "all shrink tests passed"

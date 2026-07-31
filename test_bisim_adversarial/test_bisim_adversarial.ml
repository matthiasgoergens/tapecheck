(* Adversarial tests for the per-operation mutual-raise health check.

   test_bisim_health is a POSITIVE control I designed to match my own
   theory, so it is weak evidence: I picked the case, and it agreed with
   me. These are attempts to falsify the check instead. Each scenario is
   a way the check could be wrong that I would rather find here than
   after telling Jane Street it works.

   A: FALSE POSITIVE. An operation whose raising behaviour is precisely
      what the test is checking -- both implementations must raise the
      same exception on invalid input. This is legitimate, common, and
      the check calls it "not really being compared".

   B: FALSE NEGATIVE via label collapse. The check keys on the
      constructor name from sexp_of_cmd. A perfectly ordinary cmd
      encoding -- one constructor carrying an opcode as an argument, or
      a record -- collapses every operation to a single label, which
      silently restores the aggregate behaviour the check exists to
      avoid.

   C: FALSE NEGATIVE via rarity. min_steps=20 means a broken operation
      that the generator produces rarely is never flagged at all. *)

open Base

let n_ops = 36

(* ---------- Scenario A: legitimate exception-agreement testing ---------- *)

(* Both implementations are correct. Op00 is a "pop from empty" style
   operation that raises on both sides, and checking that they raise
   ALIKE is a real property. Nothing here is broken. *)
module Legit_spec = struct
  type state = int
  type left = int list ref
  type right = int list ref
  type cmd = Pop_empty | Push of int
  type res = int

  let init_state = 0
  let init_left () = ref []
  let init_right () = ref []
  let cleanup_left _ = ()
  let cleanup_right _ = ()

  let arb_cmd _ =
    let open Base_quickcheck.Generator.Let_syntax in
    let%bind is_pop = Base_quickcheck.Generator.bool in
    if is_pop then return Pop_empty
    else
      let%bind v = Base_quickcheck.Generator.int_uniform_inclusive 0 100 in
      return (Push v)

  let precond _ _ = true
  let next_state _ s = s + 1

  let step cmd l =
    match cmd with
    | Pop_empty -> failwith "empty" (* both sides, identically: correct *)
    | Push v ->
      l := v :: !l;
      List.length !l

  let run_left cmd l = step cmd l
  let run_right cmd r = step cmd r
  let equal_res = Int.equal

  let sexp_of_cmd = function
    | Pop_empty -> Sexp.Atom "Pop_empty"
    | Push v -> Sexp.List [ Sexp.Atom "Push"; Sexp.Atom (Int.to_string v) ]

  let sexp_of_res = Int.sexp_of_t
end

(* ---------- Scenario B: label collapse ---------- *)

(* Same 5-of-36-broken defect as core#182, but with the single most
   ordinary cmd encoding imaginable: one constructor carrying the
   opcode. Every operation now shares the label "Op". *)
module Collapsed_spec = struct
  type state = int
  type left = int list ref
  type right = int list ref
  type cmd = Op of int * int
  type res = int

  let init_state = 0
  let init_left () = ref []
  let init_right () = ref []
  let cleanup_left _ = ()
  let cleanup_right _ = ()

  let arb_cmd _ =
    let open Base_quickcheck.Generator.Let_syntax in
    let%bind op = Base_quickcheck.Generator.int_uniform_inclusive 0 (n_ops - 1) in
    let%bind arg = Base_quickcheck.Generator.int_uniform_inclusive 0 100 in
    return (Op (op, arg))

  let precond _ _ = true
  let next_state _ s = s + 1

  let step (Op (op, arg)) l =
    if op < 5 then arg % 0
    else begin
      l := arg :: !l;
      op + arg + List.length !l
    end

  let run_left cmd l = step cmd l
  let run_right cmd r = step cmd r
  let equal_res = Int.equal

  let sexp_of_cmd (Op (op, arg)) =
    Sexp.List
      [ Sexp.Atom "Op"; Sexp.Atom (Int.to_string op); Sexp.Atom (Int.to_string arg) ]

  let sexp_of_res = Int.sexp_of_t
end

(* ---------- Scenario C: a rare broken operation ---------- *)

module Rare_spec = struct
  type state = int
  type left = int list ref
  type right = int list ref
  type cmd = Common of int | Rare_broken
  type res = int

  let init_state = 0
  let init_left () = ref []
  let init_right () = ref []
  let cleanup_left _ = ()
  let cleanup_right _ = ()

  (* Rare_broken shows up roughly 1 step in 400. *)
  let arb_cmd _ =
    let open Base_quickcheck.Generator.Let_syntax in
    let%bind r = Base_quickcheck.Generator.int_uniform_inclusive 0 399 in
    if r = 0 then return Rare_broken
    else
      let%bind v = Base_quickcheck.Generator.int_uniform_inclusive 0 100 in
      return (Common v)

  let precond _ _ = true
  let next_state _ s = s + 1

  let step cmd l =
    match cmd with
    | Rare_broken -> 1 % 0
    | Common v ->
      l := v :: !l;
      v + List.length !l

  let run_left cmd l = step cmd l
  let run_right cmd r = step cmd r
  let equal_res = Int.equal

  let sexp_of_cmd = function
    | Rare_broken -> Sexp.Atom "Rare_broken"
    | Common v -> Sexp.List [ Sexp.Atom "Common"; Sexp.Atom (Int.to_string v) ]

  let sexp_of_res = Int.sexp_of_t
end

module B_legit = Bisim.Make (Legit_spec)
module B_collapsed = Bisim.Make (Collapsed_spec)
module B_rare = Bisim.Make (Rare_spec)

let seed = Base_quickcheck.Test.default_config.seed

let drive (type c) ~(gen : c list Base_quickcheck.Generator.t)
      ~(sexp_of_cmd : c -> Sexp.t) ~(count : int) (test : c list -> bool) : unit =
  Base_quickcheck.Test.run_exn
    (module struct
      type t = c list

      let quickcheck_generator = gen
      let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
      let sexp_of_t = List.sexp_of_t sexp_of_cmd
    end)
    ~config:{ Base_quickcheck.Test.default_config with test_count = count; seed }
    ~f:(fun cmds -> ignore (test cmds : bool))

let show ?expected_raising name stats =
  let total = stats.Bisim.agree + stats.Bisim.agreed_by_raising + stats.Bisim.disagree in
  Stdio.printf "%s: steps %d, agreed_by_raising %d (%.3f aggregate)\n" name total
    stats.Bisim.agreed_by_raising
    (Float.of_int stats.Bisim.agreed_by_raising /. Float.of_int (Int.max 1 total));
  let ws = Bisim.ops_agreeing_only_by_raising ?expected_raising stats in
  Stdio.printf "  flagged: %d %s\n" (List.length ws)
    (Sexp.to_string (List.sexp_of_t (fun w -> Sexp.Atom w.Bisim.op) ws))

let report_of name ?op_label ?expected_raising run =
  let captured = ref [] in
  let (), stats =
    run ~report:(fun s -> captured := s :: !captured) ?op_label ?expected_raising ()
  in
  Stdio.printf "--- %s ---\n" name;
  show ?expected_raising name stats;
  (match List.rev !captured with
   | [] -> Stdio.printf "  (no report emitted)\n"
   | ls -> List.iter ls ~f:(fun s -> Stdio.printf "%s\n" s));
  Stdio.printf "\n";
  stats

let () =
  Stdio.printf "=== A: legitimate exception agreement ===\n";
  let a =
    report_of "A, default" (fun ~report ?op_label ?expected_raising () ->
      B_legit.with_health ~report ?op_label ?expected_raising
        (drive ~gen:(B_legit.gen_cmds ~max_steps:40 ())
           ~sexp_of_cmd:Legit_spec.sexp_of_cmd ~count:300))
  in
  let _a2 =
    report_of "A, with ~expected_raising:[Pop_empty]"
      ~expected_raising:[ "Pop_empty" ]
      (fun ~report ?op_label ?expected_raising () ->
         B_legit.with_health ~report ?op_label ?expected_raising
           (drive ~gen:(B_legit.gen_cmds ~max_steps:40 ())
              ~sexp_of_cmd:Legit_spec.sexp_of_cmd ~count:300))
  in
  Stdio.printf "=== B: label collapse (`type cmd = Op of int * int`) ===\n";
  let b =
    report_of "B, default" (fun ~report ?op_label ?expected_raising () ->
      B_collapsed.with_health ~report ?op_label ?expected_raising
        (drive ~gen:(B_collapsed.gen_cmds ~max_steps:40 ())
           ~sexp_of_cmd:Collapsed_spec.sexp_of_cmd ~count:300))
  in
  let b_labelled =
    report_of "B, with ~op_label naming each opcode"
      ~op_label:(fun (Collapsed_spec.Op (op, _)) -> Printf.sprintf "Op%02d" op)
      (fun ~report ?op_label ?expected_raising () ->
         B_collapsed.with_health ~report ?op_label ?expected_raising
           (drive ~gen:(B_collapsed.gen_cmds ~max_steps:40 ())
              ~sexp_of_cmd:Collapsed_spec.sexp_of_cmd ~count:300))
  in
  Stdio.printf "=== C: rare broken operation (1 step in 400) ===\n";
  let c =
    report_of "C, default" (fun ~report ?op_label ?expected_raising () ->
      B_rare.with_health ~report ?op_label ?expected_raising
        (drive ~gen:(B_rare.gen_cmds ~max_steps:40 ())
           ~sexp_of_cmd:Rare_spec.sexp_of_cmd ~count:300))
  in
  (* Assertions, so the three fixes cannot silently rot. Each was a real
     failure of the first implementation, found by trying to break it
     rather than by testing that it worked. *)
  let flagged ?expected_raising st =
    List.map (Bisim.ops_agreeing_only_by_raising ?expected_raising st)
      ~f:(fun w -> w.Bisim.op)
    |> Set.of_list (module String)
  in
  let checks =
    [ ( "A: legitimate exception agreement is flagged by default"
      , Set.equal (flagged a) (Set.of_list (module String) [ "Pop_empty" ]) )
    ; ( "A: ~expected_raising silences it"
      , Set.is_empty (flagged ~expected_raising:[ "Pop_empty" ] a) )
    ; ( "B: label collapse is DETECTED and announced, not silently useless"
      , Bisim.label_resolution_is_degenerate b )
    ; ( "B: with ~op_label the same defect is caught (5 operations)"
      , Set.length (flagged b_labelled) = 5 )
    ; ( "C: a rare broken op is surfaced as undersampled, not dropped"
      , not (List.is_empty (Bisim.ops_undersampled c)) )
    ]
  in
  Stdio.printf "=== ASSERTIONS ===\n";
  let bad = ref 0 in
  List.iter checks ~f:(fun (name, ok) ->
    if not ok then Int.incr bad;
    Stdio.printf "  %-4s %s\n" (if ok then "ok" else "FAIL") name);
  if !bad > 0 then Stdlib.exit 1

(* Positive control for Bisim's mutual-raise health check, built to the
   shape of janestreet/core#182.

   The point being demonstrated is NOT "the check works". It is that the
   AGGREGATE form of the check does not, and would have stayed silent on
   the real bug, while the per-operation form fires loudly. Without this
   test the aggregate version looks perfectly reasonable.

   core#182: 36 operations, of which 5 (Exists, Filter_inplace, For_all,
   Find_elt, Find) took a predicate that raised Division_by_zero
   unconditionally. Both the real implementation and the reference
   raised, identically, so every such step was counted as agreement and
   skipped. Those 5 operations were never actually compared -- for about
   six years. *)

open Base

let n_ops = 36
let n_broken = 5

module Make_spec (C : sig
    val broken : int
  end) =
struct
  type state = int
  type left = int list ref
  type right = int list ref

  (* op index, argument *)
  type cmd = int * int
  type res = int

  let init_state = 0
  let init_left () = ref []
  let init_right () = ref []
  let cleanup_left _ = ()
  let cleanup_right _ = ()

  let arb_cmd _state =
    let open Base_quickcheck.Generator.Let_syntax in
    let%bind op = Base_quickcheck.Generator.int_uniform_inclusive 0 (n_ops - 1) in
    let%bind arg = Base_quickcheck.Generator.int_uniform_inclusive 0 100 in
    return (op, arg)

  let precond _ _ = true
  let next_state _ s = s + 1

  (* The two implementations are genuinely identical -- that is the
     whole point. There is no bug in the "implementation"; the defect is
     that 5 of the operations never compare anything, because the
     predicate they use raises before producing a value. *)
  let step ((op, arg) : cmd) (l : int list ref) : res =
    if op < C.broken then begin
      (* stands in for `n mod 0` in the original *)
      let divisor = 0 in
      arg % divisor
    end
    else begin
      l := arg :: !l;
      op + arg + List.length !l
    end

  let run_left cmd l = step cmd l
  let run_right cmd r = step cmd r
  let equal_res = Int.equal

  let sexp_of_cmd ((op, arg) : cmd) : Sexp.t =
    Sexp.List [ Sexp.Atom (Printf.sprintf "Op%02d" op); Sexp.Atom (Int.to_string arg) ]

  let sexp_of_res = Int.sexp_of_t
end

module Broken_spec = Make_spec (struct
    let broken = n_broken
  end)

(* Negative control. Identical in every respect except that no
   operation raises. If the check fires here too it is worthless -- it
   would just be flagging every bisimulation ever written. *)
module Healthy_spec = Make_spec (struct
    let broken = 0
  end)

module B_broken = Bisim.Make (Broken_spec)
module B_healthy = Bisim.Make (Healthy_spec)

let seed = Base_quickcheck.Test.default_config.seed

let drive (type c) ~(gen : c list Base_quickcheck.Generator.t)
      ~(sexp_of_cmd : c -> Sexp.t) (test : c list -> bool) : unit =
  Base_quickcheck.Test.run_exn
    (module struct
      type t = c list

      let quickcheck_generator = gen
      let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
      let sexp_of_t = List.sexp_of_t sexp_of_cmd
    end)
    ~config:{ Base_quickcheck.Test.default_config with test_count = 300; seed }
    ~f:(fun cmds -> ignore (test cmds : bool))

let () =
  Stdio.printf "=== SCENARIO 1: the core#182 shape (5 of 36 ops raise) ===\n\n";
  let captured = ref [] in
  let (), stats =
    B_broken.with_health
      ~report:(fun s -> captured := s :: !captured)
      (drive
         ~gen:(B_broken.gen_cmds ~max_steps:40 ())
         ~sexp_of_cmd:Broken_spec.sexp_of_cmd)
  in
  let stats_snapshot = Bisim.snapshot stats in
  let total =
    stats_snapshot.agree + stats_snapshot.agreed_by_raising
    + stats_snapshot.disagree
  in
  Stdio.printf "steps: %d  agree: %d  agreed_by_raising: %d  disagree: %d\n"
    total stats_snapshot.agree stats_snapshot.agreed_by_raising
    stats_snapshot.disagree;
  Stdio.printf "aggregate mutual-raise ratio: %.3f\n"
    (Float.of_int stats_snapshot.agreed_by_raising /. Float.of_int total);
  Stdio.printf "AGGREGATE check (threshold 0.5): %b   <-- stays SILENT\n"
    (Bisim.most_steps_agreed_only_by_raising stats);
  let warnings = Bisim.ops_agreeing_only_by_raising stats in
  Stdio.printf "PER-OPERATION check: %d operations flagged\n\n"
    (List.length warnings);
  List.iter (List.rev !captured) ~f:(fun s -> Stdio.printf "%s\n" s);
  let flagged = List.map warnings ~f:(fun w -> w.op) |> Set.of_list (module String) in
  let expected =
    List.init n_broken ~f:(fun i -> Printf.sprintf "Op%02d" i)
    |> Set.of_list (module String)
  in
  Stdio.printf "\n=== SCENARIO 2: negative control (no op raises) ===\n\n";
  let captured_h = ref [] in
  let (), stats_h =
    B_healthy.with_health
      ~report:(fun s -> captured_h := s :: !captured_h)
      (drive
         ~gen:(B_healthy.gen_cmds ~max_steps:40 ())
         ~sexp_of_cmd:Healthy_spec.sexp_of_cmd)
  in
  let stats_h_snapshot = Bisim.snapshot stats_h in
  let total_h =
    stats_h_snapshot.agree + stats_h_snapshot.agreed_by_raising
    + stats_h_snapshot.disagree
  in
  Stdio.printf "steps: %d  agree: %d  agreed_by_raising: %d  disagree: %d\n"
    total_h stats_h_snapshot.agree stats_h_snapshot.agreed_by_raising
    stats_h_snapshot.disagree;
  Stdio.printf "operations flagged: %d\n"
    (List.length (Bisim.ops_agreeing_only_by_raising stats_h));
  Stdio.printf "reports emitted: %d\n" (List.length !captured_h);
  Stdio.printf "\n=== VERDICT ===\n";
  Stdio.printf "broken: flagged exactly the broken operations:      %b\n"
    (Set.equal flagged expected);
  Stdio.printf "broken: aggregate check stayed silent (dilution):   %b\n"
    (not (Bisim.most_steps_agreed_only_by_raising stats));
  Stdio.printf "broken: report emitted without being asked for:     %b\n"
    (not (List.is_empty !captured));
  Stdio.printf "healthy: no operations flagged (no false positive): %b\n"
    (List.is_empty (Bisim.ops_agreeing_only_by_raising stats_h));
  Stdio.printf "healthy: stayed quiet (no report emitted):          %b\n"
    (List.is_empty !captured_h);
  (* Assert, do not merely print. These four properties are the whole
     point of the per-operation health check, and each was arrived at by
     a measurement that contradicted an earlier design:
       - per-operation, because the AGGREGATE ratio is 0.144 here and a
         0.5 threshold stays silent on the very bug it was written for
       - default-on, because an opt-in statistic is how janestreet/core
         #182 survived six years
       - no false positive on a healthy spec, because "flags 5 of 36" is
         also what a check that flags everything would report *)
  let ok =
    Set.equal flagged expected
    && not (Bisim.most_steps_agreed_only_by_raising stats)
    && (not (List.is_empty !captured))
    && List.is_empty (Bisim.ops_agreeing_only_by_raising stats_h)
    && List.is_empty !captured_h
  in
  if not ok then begin
    Stdio.printf "\nFAIL: bisim health check regressed. See\n\
                 \  coordinate-work/open-items.md (janestreet/core#182) for why\n\
                 \  each of these assertions exists.\n";
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_bisim_health: all assertions passed\n"

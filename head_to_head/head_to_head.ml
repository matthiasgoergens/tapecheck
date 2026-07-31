(* Head-to-head: tapecheck's choice-tape Bisim engine versus
   qcheck-stm, same bug, same argument ranges, same
   per-trial generation budget. This is the number the whole task is
   about; everything else is scaffolding around it.

   Property under test: queue_fixture/fast_queue.ml's seeded bug (a
   two-list queue that forgets to clear [back] after a refill), run
   against a plain-list reference via a sequence of Enqueue/Dequeue
   operations. Both arms:
     - draw operations from the identical distribution (Enqueue of an
       int in [0, 1000], or Dequeue, chosen with equal probability);
     - search up to 200 generated cases per trial for a first failure
       (tapecheck's [Tape_engine.run ~count], qcheck-stm's
       [Test.make_cell ~count] -- both semantically "stop at the first
       failing case within this many valid draws", though the exact
       search order differs since qcheck-stm draws one value per
       [count] slot up front rather than early-exiting on the first
       failure the way tapecheck's engine does; see the write-up for
       the caveat this implies for the "avg attempts" comparison);
     - report whether the true 3-op minimal [Enqueue 0; Dequeue;
       Dequeue] was reached, and a shrink-cost metric (tapecheck:
       [attempts], the shrink-phase proposal count; qcheck-stm:
       [shrink_steps], the counterexample's own reported shrink-step
       count -- NOT the same unit, see write-up).

   qcheck-stm side note: [arb_cmd] is written state-independent here
   (matching queue_fixture's actual shape), which is qcheck-stm at its
   best case for this specific property -- the property does not need
   the "handle produced by an earlier op" scenario that this survey's
   own case for tapecheck's advantage rests on (see stateful.ml's doc
   comment and the write-up's "who this beats" section). This first
   scenario is deliberately NOT the adversarial case; it measures
   ordinary shrink quality/cost on a property both engines can express
   equally naturally, which is a fair, if less dramatic, comparison.

   A SECOND scenario below (handle-allocator) IS the adversarial case:
   a later operation's argument (which bundle entry to use) is chosen
   relative to how many entries exist at that point, so deleting an
   EARLIER, unrelated entry shifts what index later operations should
   reference. tapecheck's replay re-derives that index fresh from the
   actual post-deletion bundle; qcheck-stm's shrinker replays the
   original, now-stale index and falls back to its precondition filter
   when that no longer lines up -- see stateful/stateful.ml's doc
   comment and outreach/hypothesis-inventory.md's stateful-testing
   section for why this is expected to be where the two diverge. *)

open! Base
open Stdio

let max_steps = 60
let cases_per_trial = 200
(* On seeds: both arms are handed the same integer, but they feed it to
   different PRNGs (Tape_engine.run ~seed vs Stdlib.Random.State.make),
   so the generated sequences differ. Sharing the integer is COSMETIC --
   it buys no pairing and should not be described as running both
   engines on identical inputs. The comparison rests on averaging over
   [trials] seeds, not on matched pairs. A genuinely paired design would
   generate each counterexample once and hand BOTH shrinkers the same
   starting point; that would cut variance substantially and is the
   right shape if these numbers ever need tightening. As it stands the
   effect is far larger than the noise: 300/300 vs 232/300 is a 95% CI
   of [0.726, 0.821] against a rule-of-three lower bound of 0.99. *)
let trials = 300

(* ---------- Arm 1: tapecheck (Bisim) ---------- *)

module Q_tape = struct
  type state = unit
  type left = int list ref
  type right = Fast_queue.t
  type res = int option

  type cmd =
    | Enqueue of int
    | Dequeue
  [@@deriving sexp_of]

  let init_state = ()
  let init_left () : left = ref []
  let init_right () : right = Fast_queue.create ()
  let cleanup_left (_ : left) = ()
  let cleanup_right (_ : right) = ()

  let arb_cmd (() : state) : cmd Base_quickcheck.Generator.t =
    let module G = Base_quickcheck.Generator in
    G.union
      [ G.map (G.int_uniform_inclusive 0 1000) ~f:(fun v -> Enqueue v)
      ; G.return Dequeue
      ]

  let precond (_ : cmd) (() : state) = true
  let next_state (_ : cmd) (() : state) = ()

  let run_left (cmd : cmd) (left : left) : res =
    match cmd with
    | Enqueue v ->
      left := !left @ [ v ];
      None
    | Dequeue -> (
      match !left with
      | x :: rest ->
        left := rest;
        Some x
      | [] -> None)

  let run_right (cmd : cmd) (right : right) : res =
    match cmd with
    | Enqueue v ->
      Fast_queue.enqueue right v;
      None
    | Dequeue -> Fast_queue.dequeue right

  let equal_res = Option.equal Int.equal
  let sexp_of_res = [%sexp_of: int option]
end

module Tape_arm = Bisim.Make (Q_tape)

let is_exact_minimal (cmds : Q_tape.cmd list) =
  match cmds with
  | [ Q_tape.Enqueue 0; Q_tape.Dequeue; Q_tape.Dequeue ] -> true
  | _ -> false

type arm_result =
  { exact_minimal : bool
  ; op_count : int
  ; cost : int (* tapecheck: attempts; qcheck-stm: shrink_steps *)
  ; shown : string (* printable form, for reporting the worst non-minimal *)
  }

let run_tape_trial ~seed : arm_result option =
  match
    Tape_engine.run
      (Tape_arm.gen_cmds ~max_steps ())
      ~test:Tape_arm.test ~seed ~count:cases_per_trial ~size:10 ~budget:5000
  with
  | Tape_engine.Passed _ -> None
  | Tape_engine.Failed { minimal; attempts; _ } ->
    Some
      { exact_minimal = is_exact_minimal minimal
      ; op_count = List.length minimal
      ; cost = attempts
      ; shown = Sexp.to_string ([%sexp_of: Q_tape.cmd list] minimal)
      }

(* ---------- Arm 2: qcheck-stm ---------- *)

module Q_stm = struct
  open QCheck
  open STM

  type sut = Fast_queue.t
  type state = int list

  type cmd =
    | Enqueue of int
    | Dequeue

  let show_cmd = function
    | Enqueue v -> Printf.sprintf "Enqueue %d" v
    | Dequeue -> "Dequeue"

  (* Per-command argument shrinker: without this, QCheck.make's default
     is no shrinking at all for the wrapped int, and qcheck-stm's
     Shrink.list (per STM_sequential.ml/qcstm's shrink_list) falls back
     to Shrink.nil for individual elements -- i.e. omitting ~shrink
     here would silently hobble qcheck-stm's OWN capability, not
     reflect a real limitation of it. A qcheck-stm user who wants
     argument shrinking (as any real test of this property would)
     writes exactly this. *)
  let shrink_cmd = function
    | Enqueue v -> QCheck.Iter.map (fun v -> Enqueue v) (QCheck.Shrink.int v)
    | Dequeue -> QCheck.Iter.empty

  let init_sut () : sut = Fast_queue.create ()
  let cleanup (_ : sut) = ()

  (* Same distribution as the tapecheck arm: Enqueue of [0,1000] or
     Dequeue, equal probability, state-independent. *)
  let arb_cmd (_ : state) =
    QCheck.make ~print:show_cmd ~shrink:shrink_cmd
      (Gen.oneof
         [ Gen.map (fun v -> Enqueue v) (Gen.int_range 0 1000)
         ; Gen.return Dequeue
         ])

  let next_state (c : cmd) (s : state) =
    match c with
    | Enqueue v -> s @ [ v ]
    | Dequeue -> ( match s with _ :: rest -> rest | [] -> [])

  let run (c : cmd) (sut : sut) : res =
    match c with
    | Enqueue v -> Res (unit, Fast_queue.enqueue sut v)
    | Dequeue -> Res (option int, Fast_queue.dequeue sut)

  let init_state : state = []
  let precond (_ : cmd) (_ : state) = true

  let postcond (c : cmd) (s : state) (res : res) =
    match (c, res) with
    | Enqueue _, Res ((Unit, _), _) -> true
    | Dequeue, Res ((Option Int, _), v) ->
      Poly.equal v (match s with x :: _ -> Some x | [] -> None)
    | _ -> false
end

module Stm_arm = STM_sequential.Make (Q_stm)

let is_exact_minimal_stm (cmds : Q_stm.cmd list) =
  match cmds with
  | [ Q_stm.Enqueue 0; Q_stm.Dequeue; Q_stm.Dequeue ] -> true
  | _ -> false

let run_stm_trial ~seed : arm_result option =
  let cell =
    QCheck.Test.make_cell ~count:cases_per_trial ~name:"queue-bisim"
      (Stm_arm.arb_cmds Q_stm.init_state)
      Stm_arm.agree_prop
  in
  let result =
    QCheck.Test.check_cell ~rand:(Stdlib.Random.State.make [| seed |]) cell
  in
  match QCheck.TestResult.get_state result with
  | QCheck.TestResult.Success -> None
  | QCheck.TestResult.Failed_other _ -> None
  | QCheck.TestResult.Error _ ->
    (* qcheck-stm's [agree_prop] itself catches divergence via
       [check_disagree]/exceptions internally and returns a bool, so an
       [Error] here would mean something raised THROUGH the property
       (not a divergence, an actual uncaught exception) -- shouldn't
       happen for this property, but don't silently misreport it as
       "no bug found" if it does. *)
    Some { exact_minimal = false; op_count = -1; cost = -1; shown = "<error>" }
  | QCheck.TestResult.Failed { instances } -> (
    match instances with
    | [] -> None
    | { instance; shrink_steps; _ } :: _ ->
      Some
        { exact_minimal = is_exact_minimal_stm instance
        ; op_count = List.length instance
        ; cost = shrink_steps
        ; shown = String.concat ~sep:"; " (List.map instance ~f:Q_stm.show_cmd)
        })

(* ---------- Scenario 2: handle allocator (the adversarial case) ---------- *)
(* Same bug/shape as test_stateful/test_stateful.ml's HandleAlloc:
   Alloc pushes a value (newest-first); Use/Free reference an existing
   entry by index; using a handle whose value is >= 100 is the bug.
   The minimal failing sequence is exactly [Alloc 100; Use 0]. *)

module H_tape = struct
  type state = { handles : int Stateful.Bundle.t }
  type sut = int list ref
  type res = int

  type cmd =
    | Alloc of int
    | Use of int
    | Free of int
  [@@deriving sexp_of]

  let init_state = { handles = Stateful.Bundle.empty }
  let init_sut () : sut = ref []
  let cleanup (_ : sut) = ()

  let arb_cmd (state : state) : cmd Base_quickcheck.Generator.t =
    let module G = Base_quickcheck.Generator in
    Stateful.rules
      [ (true, G.map (G.int_uniform_inclusive 0 1000) ~f:(fun v -> Alloc v))
      ; ( not (Stateful.Bundle.is_empty state.handles)
        , G.map (Stateful.Bundle.gen_index state.handles) ~f:(fun i -> Use i) )
      ; ( not (Stateful.Bundle.is_empty state.handles)
        , G.map (Stateful.Bundle.gen_index state.handles) ~f:(fun i -> Free i) )
      ]

  let precond (cmd : cmd) (state : state) =
    match cmd with
    | Alloc _ -> true
    | Use i | Free i -> i >= 0 && i < Stateful.Bundle.length state.handles

  let next_state (cmd : cmd) (state : state) : state =
    match cmd with
    | Alloc v -> { handles = Stateful.Bundle.push state.handles v }
    | Use _ -> state
    | Free i -> { handles = Stateful.Bundle.remove state.handles i }

  let run (cmd : cmd) (sut : sut) : res =
    match cmd with
    | Alloc v ->
      sut := v :: !sut;
      0
    | Use i -> List.nth_exn !sut i
    | Free i ->
      sut := List.filteri !sut ~f:(fun j _ -> j <> i);
      0

  let postcond (cmd : cmd) (_state : state) (res : res) =
    match cmd with
    | Use _ -> res < 100
    | Alloc _ | Free _ -> true

  let invariant (state : state) (sut : sut) =
    Stateful.Bundle.length state.handles = List.length !sut
end

module Handle_tape_arm = Stateful.Make (H_tape)

let is_handle_minimal (cmds : H_tape.cmd list) =
  match cmds with
  | [ H_tape.Alloc 100; H_tape.Use 0 ] -> true
  | _ -> false

let run_handle_tape_trial ~seed : arm_result option =
  match
    Tape_engine.run
      (Handle_tape_arm.gen_cmds ~max_steps:12 ())
      ~test:Handle_tape_arm.test ~seed ~count:cases_per_trial ~size:10
      ~budget:5000
  with
  | Tape_engine.Passed _ -> None
  | Tape_engine.Failed { minimal; attempts; _ } ->
    Some
      { exact_minimal = is_handle_minimal minimal
      ; op_count = List.length minimal
      ; cost = attempts
      ; shown = Sexp.to_string ([%sexp_of: H_tape.cmd list] minimal)
      }

module H_stm = struct
  open QCheck
  open STM

  type sut = int list ref
  type state = int list (* newest-first, mirrors Stateful.Bundle *)

  type cmd =
    | Alloc of int
    | Use of int
    | Free of int

  let show_cmd = function
    | Alloc v -> Printf.sprintf "Alloc %d" v
    | Use i -> Printf.sprintf "Use %d" i
    | Free i -> Printf.sprintf "Free %d" i

  let shrink_cmd = function
    | Alloc v -> QCheck.Iter.map (fun v -> Alloc v) (QCheck.Shrink.int v)
    | Use i -> QCheck.Iter.map (fun i -> Use i) (QCheck.Shrink.int i)
    | Free i -> QCheck.Iter.map (fun i -> Free i) (QCheck.Shrink.int i)

  (* State-dependent, like HashtblModel's [arb_cmd] in qcheck-stm's own
     example: only offer Use/Free once something has been allocated,
     and draw a valid index -- exactly matching the tapecheck arm's
     [Stateful.rules]/[Bundle.gen_index] gating, so any difference in
     outcome is down to shrinking, not to generation offering an
     unfair (e.g. more/less often out-of-range) distribution. *)
  let arb_cmd (s : state) =
    let n = List.length s in
    QCheck.make ~print:show_cmd ~shrink:shrink_cmd
      (if n = 0 then Gen.map (fun v -> Alloc v) (Gen.int_range 0 1000)
       else
         Gen.oneof
           [ Gen.map (fun v -> Alloc v) (Gen.int_range 0 1000)
           ; Gen.map (fun i -> Use i) (Gen.int_bound (n - 1))
           ; Gen.map (fun i -> Free i) (Gen.int_bound (n - 1))
           ])

  let init_sut () : sut = ref []
  let cleanup (_ : sut) = ()

  let next_state (c : cmd) (s : state) =
    match c with
    | Alloc v -> v :: s
    | Use _ -> s
    | Free i -> List.filteri s ~f:(fun j _ -> j <> i)

  let run (c : cmd) (sut : sut) : res =
    match c with
    | Alloc v ->
      sut := v :: !sut;
      Res (unit, ())
    | Use i -> Res (int, List.nth_exn !sut i)
    | Free i ->
      sut := List.filteri !sut ~f:(fun j _ -> j <> i);
      Res (unit, ())

  let init_state : state = []

  let precond (c : cmd) (s : state) =
    match c with
    | Alloc _ -> true
    | Use i | Free i -> i >= 0 && i < List.length s

  let postcond (c : cmd) (_s : state) (res : res) =
    match (c, res) with
    | Use _, Res ((Int, _), v) -> v < 100
    | (Alloc _ | Free _), Res ((Unit, _), _) -> true
    | _ -> false
end

module Handle_stm_arm = STM_sequential.Make (H_stm)

let is_handle_minimal_stm (cmds : H_stm.cmd list) =
  match cmds with
  | [ H_stm.Alloc 100; H_stm.Use 0 ] -> true
  | _ -> false

let run_handle_stm_trial ~seed : arm_result option =
  let cell =
    QCheck.Test.make_cell ~count:cases_per_trial ~name:"handle-alloc"
      (Handle_stm_arm.arb_cmds H_stm.init_state)
      Handle_stm_arm.agree_prop
  in
  let result =
    QCheck.Test.check_cell ~rand:(Stdlib.Random.State.make [| seed |]) cell
  in
  match QCheck.TestResult.get_state result with
  | QCheck.TestResult.Success -> None
  | QCheck.TestResult.Failed_other _ -> None
  | QCheck.TestResult.Error _ ->
    Some { exact_minimal = false; op_count = -1; cost = -1; shown = "<error>" }
  | QCheck.TestResult.Failed { instances } -> (
    match instances with
    | [] -> None
    | { instance; shrink_steps; _ } :: _ ->
      Some
        { exact_minimal = is_handle_minimal_stm instance
        ; op_count = List.length instance
        ; cost = shrink_steps
        ; shown = String.concat ~sep:"; " (List.map instance ~f:H_stm.show_cmd)
        })


(* ---------- Boosted qcheck-stm: grant it far more shrink effort ----------

   Reading QCheck2.Test.shrink_ (qcheck-core 0.91,
   _opam/lib/qcheck-core/QCheck2.ml:1885-1935) shows the shrink loop
   recurses on every success and stops only when NO candidate fails:

     match i' with
     | None -> i, r, m, steps
     | Some (i_tree',r',m') -> shrink_ st i_tree' r' m' ~steps:(steps + 1)

   There is no step cap and no budget parameter, so qcheck-stm's output
   is already a fixpoint of its own shrinker and "it ran out of effort"
   should be impossible. That is an argument from source, though, not a
   measurement. This arm measures it: take the counterexample qcheck-stm
   settled on and shrink it again from scratch, with its own shrinker,
   repeatedly, until it stops changing or [passes] rounds elapse.

   If the 232/300 figure were an effort artefact, extra rounds would
   improve it. If the shrinker structurally cannot construct the smaller
   candidate -- because deleting an earlier Alloc leaves a later Use
   pointing at an index that no longer exists, so the case stops failing
   and the deletion is rejected -- then no amount of extra effort moves
   it. *)
(* Harness self-check. A boosted arm that silently does nothing produces
   exactly the same numbers as a boosted arm that works and finds
   nothing, so count what actually happened. *)
let reshrink_calls = ref 0
let reshrink_reproduced = ref 0
let reshrink_fellthrough = ref 0
let reshrink_improved = ref 0

let reshrink_handle_stm (cex : H_stm.cmd list) : H_stm.cmd list * int =
  Int.incr reshrink_calls;
  let base = Handle_stm_arm.arb_cmds H_stm.init_state in
  let arb =
    QCheck.make
      ?print:base.QCheck.print
      ?shrink:base.QCheck.shrink
      (QCheck.Gen.return cex)
  in
  let cell =
    QCheck.Test.make_cell ~count:1 ~name:"handle-alloc-reshrink" arb
      Handle_stm_arm.agree_prop
  in
  let result =
    QCheck.Test.check_cell ~rand:(Stdlib.Random.State.make [| 1 |]) cell
  in
  match QCheck.TestResult.get_state result with
  | QCheck.TestResult.Failed { instances = { instance; shrink_steps; _ } :: _ } ->
    Int.incr reshrink_reproduced;
    if not (List.equal Poly.equal instance cex) then Int.incr reshrink_improved;
    (instance, shrink_steps)
  | _ ->
    Int.incr reshrink_fellthrough;
    (cex, 0)

let run_handle_stm_trial_boosted ~passes ~seed : arm_result option =
  match run_handle_stm_trial ~seed with
  | None -> None
  | Some first ->
    if first.op_count < 0 then Some first
    else begin
      (* Recover the command list by re-running; run_handle_stm_trial
         only hands back a printed form, so redo the shrink loop over
         the structured value. *)
      let cell =
        QCheck.Test.make_cell ~count:cases_per_trial ~name:"handle-alloc"
          (Handle_stm_arm.arb_cmds H_stm.init_state)
          Handle_stm_arm.agree_prop
      in
      let result =
        QCheck.Test.check_cell ~rand:(Stdlib.Random.State.make [| seed |]) cell
      in
      match QCheck.TestResult.get_state result with
      | QCheck.TestResult.Failed { instances = { instance; shrink_steps; _ } :: _ }
        ->
        let rec go cur cost n =
          if n = 0 then (cur, cost)
          else begin
            let next, extra = reshrink_handle_stm cur in
            if List.equal Poly.equal next cur then (cur, cost + extra)
            else go next (cost + extra) (n - 1)
          end
        in
        let final, total_cost = go instance shrink_steps passes in
        Some
          { exact_minimal = is_handle_minimal_stm final
          ; op_count = List.length final
          ; cost = total_cost
          ; shown = String.concat ~sep:"; " (List.map final ~f:H_stm.show_cmd)
          }
      | _ -> Some first
    end

(* ---------- Run both arms over the same seeds, report ---------- *)

type summary =
  { mutable found : int
  ; mutable exact_minimal : int
  ; mutable total_op_count : int
  ; mutable total_cost : int
  ; mutable max_op_count : int
  ; mutable worst : string option
      (* the longest non-exact-minimal result seen, for concrete evidence
         of what "stuck" looks like (shrink_table.ml's own convention) *)
  }

let new_summary () =
  { found = 0; exact_minimal = 0; total_op_count = 0; total_cost = 0
  ; max_op_count = 0; worst = None
  }

let note (s : summary) (r : arm_result) =
  s.found <- s.found + 1;
  if r.exact_minimal then s.exact_minimal <- s.exact_minimal + 1
  else begin
    match s.worst with
    | Some w when String.length w >= String.length r.shown -> ()
    | _ -> s.worst <- Some r.shown
  end;
  s.total_op_count <- s.total_op_count + r.op_count;
  s.total_cost <- s.total_cost + r.cost;
  s.max_op_count <- max s.max_op_count r.op_count

let print_summary name (s : summary) =
  printf
    "  %-10s found %3d/%d, exact minimal %3d/%d, avg ops in minimal %.2f, \
     max ops %d, avg shrink cost %.1f\n"
    name s.found trials s.exact_minimal trials
    (if s.found > 0 then Float.of_int s.total_op_count /. Float.of_int s.found
     else 0.)
    s.max_op_count
    (if s.found > 0 then Float.of_int s.total_cost /. Float.of_int s.found
     else 0.);
  Option.iter s.worst ~f:(fun w -> printf "  %-10s worst non-minimal: %s\n" name w)

let run_scenario ~title ~run_tape ~run_stm =
  printf "\n%s -- %d trials, %d cases/trial\n" title trials cases_per_trial;
  let tape_summary = new_summary () and stm_summary = new_summary () in
  for trial = 0 to trials - 1 do
    let seed = trial * 1_000_003 in
    Option.iter (run_tape ~seed) ~f:(note tape_summary);
    Option.iter (run_stm ~seed) ~f:(note stm_summary)
  done;
  print_summary "tapecheck" tape_summary;
  print_summary "qcheck-stm" stm_summary

let () =
  run_scenario
    ~title:
      "Scenario 1: queue bisimulation (fair case, no handle-referencing)"
    ~run_tape:run_tape_trial ~run_stm:run_stm_trial;
  run_scenario
    ~title:
      "Scenario 2: handle allocator (adversarial case: later ops reference \
       earlier ones)"
    ~run_tape:run_handle_tape_trial ~run_stm:run_handle_stm_trial;
  run_scenario
    ~title:
      "Scenario 3: handle allocator, qcheck-stm granted 20 extra full shrink \
       passes (tests whether 232/300 is an effort artefact)"
    ~run_tape:run_handle_tape_trial
    ~run_stm:(run_handle_stm_trial_boosted ~passes:20);
  printf
    "\n  boosted-arm self-check: reshrink called %d times, reproduced the \
     failure %d, fell through %d, changed the case %d\n"
    !reshrink_calls !reshrink_reproduced !reshrink_fellthrough
    !reshrink_improved

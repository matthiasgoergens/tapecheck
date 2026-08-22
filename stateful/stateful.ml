(* Stateful / rule-based model testing, ported from Python Hypothesis's
   RuleBasedStateMachine (stateful.html; source stateful.py -- see
   outreach/hypothesis-inventory.md section 9 for the design notes this
   follows). API shape (Spec with init_state/init_sut/arb_cmd/precond/
   next_state/run/postcond) is deliberately close to qcheck-stm's
   Sig/StateModel, since that is the OCaml vocabulary users already
   know (ocaml-multicore/multicoretests, lib/STM.ml) -- same division
   of labour between a pure model [state] and the real [sut], same
   command/precondition/postcondition/next_state names.

   The one load-bearing difference from qcheck-stm is HOW the command
   sequence is generated. qcheck-stm's [gen_cmds] builds a concrete
   [cmd list] value up front (an ordinary QCheck rose-tree value), and
   its shrinker (a [Shrink.list_elems]-composed [Iter.t]) edits that
   list directly, replaying the ORIGINAL, now-fixed argument values of
   surviving commands against a re-derived model state; a filter
   ([cmds_ok]) then discards any shrunk sequence whose fixed commands
   no longer satisfy their preconditions, with no way to substitute a
   fresh, valid command in the gap. tapecheck's [gen_cmds] below is
   instead an ordinary state-dependent BIND generator -- the exact
   "length-prefixed list" shape the tape engine already shrinks well
   (see README.md's bind row and test_bq/test_shrink.ml): a length
   choice, then one recursive [arb_cmd state] per step, threading
   [next_state] the same way qcheck-stm does. Shrinking this generator
   costs the tape engine ZERO new machinery -- [lower_and_delete] in
   engine/tape_engine.ml already lowers the length choice while
   deleting a contiguous later block, and REPLAYS the (unmodified)
   recursive generator, so a step downstream of a deletion is
   regenerated fresh against the ACTUAL post-deletion state rather than
   replayed as a stale fixed value. A [Bundle]-consuming command whose
   argument is "an index into whatever the bundle currently holds"
   therefore re-targets a surviving entry automatically when an earlier
   producer is deleted, rather than being filtered out wholesale. The
   behaviour is exercised directly by [test_stateful].

   Deliberately NOT ported: Hypothesis's own reflection-based rule
   collection (@rule/@precondition method decorators discovered via
   inspect.getmembers) and its swarm-testing feature-omission mode --
   both are orthogonal conveniences, not shrinking-relevant, and would
   cost real design work for no measurement payoff here. [rules] below
   is the whole of what's ported from "how a rule gets offered": a
   precondition-gated choice among generators, matching Hypothesis's
   @precondition (gates which rules are even offered, preferred over
   assume() inside a rule body because it doesn't waste a generated
   step on an ineligible rule) more closely than qcheck-stm's approach
   (qcheck-stm generates unconditionally and relies on [precond] plus
   [Shrink.filter] to reject bad sequences after the fact). *)

open! Base
module G = Base_quickcheck.Generator

(* Threads values produced by one command to arguments of a later one
   (Hypothesis's Bundle / qcheck-stm's "Var" indices into prior
   results). Newest-first, mirroring Hypothesis's Bundle: its consuming
   draw is a reversed [sampled_from] so that shrinking prefers deleting
   OLDER entries first (outreach/hypothesis-inventory.md sec 9). This
   is intentionally just a list threaded through your own [state] type
   -- there is no hidden machinery here, only names, so the tape's
   ordinary integer-choice clamping (see [gen_index]) does the actual
   shrink-coherence work described above. *)
module Bundle = struct
  type 'a t = 'a list

  let empty : 'a t = []
  let push (t : 'a t) (x : 'a) : 'a t = x :: t
  let is_empty (t : 'a t) = List.is_empty t
  let length (t : 'a t) = List.length t

  (* An ordinary bounded integer choice. On a shrink replay the tape
     clamps whatever value used to be recorded here into [0, length
     t - 1] AT THE CURRENT (possibly smaller) length, so a command that
     used to reference an entry a deleted producer created re-targets a
     surviving entry instead of the proposal being rejected outright.
     Callers must gate on [not (is_empty t)] (e.g. via [rules] below)
     before offering a command that calls this. *)
  let gen_index (t : 'a t) : int G.t = G.int_uniform_inclusive 0 (length t - 1)

  let get (t : 'a t) (i : int) : 'a = List.nth_exn t i

  (* Newest-first order means index 0 is the most recently pushed
     entry; [remove] keeps that order for the rest. *)
  let remove (t : 'a t) (i : int) : 'a t =
    List.filteri t ~f:(fun j _ -> j <> i)
end

(* Precondition-gated rule choice: offers only the generators whose
   guard holds against the current state, then picks uniformly among
   those (Hypothesis's RuleStrategy/@precondition, see the module doc
   above). Raises if none are enabled -- a Spec's [arb_cmd] should
   always include at least one always-enabled rule so no state is a
   dead end (matching Hypothesis's own requirement that the class have
   at least one rule offered at every step). *)
let rules (choices : (bool * 'cmd G.t) list) : 'cmd G.t =
  match List.filter_map choices ~f:(fun (ok, g) -> if ok then Some g else None) with
  | [] -> failwith "Stateful.rules: no rule's precondition holds for this state"
  | enabled -> G.union enabled

module type Spec = sig
  type state
  type sut
  type cmd
  type res

  val init_state : state
  val init_sut : unit -> sut
  val cleanup : sut -> unit

  (* Only commands whose precondition holds against [state] should have
     nonzero probability -- typically built with [rules] above. *)
  val arb_cmd : state -> cmd G.t
  val precond : cmd -> state -> bool
  val next_state : cmd -> state -> state
  val run : cmd -> sut -> res
  val postcond : cmd -> state -> res -> bool

  (* Checked after [init_sut] and after every accepted step (Hypothesis's
     @invariant, run after @initialize and after each rule; qcheck-stm
     has no equivalent -- its [postcond] is the only correctness check). *)
  val invariant : state -> sut -> bool

  val sexp_of_cmd : cmd -> Sexp.t
end

let default_max_steps = 50

module Make (S : Spec) = struct
  (* State-dependent, length-prefixed bind generator: see the module
     doc comment above for why this specific shape is what gives the
     tape engine its shrink-coherence advantage over qcheck-stm's fixed
     rose-tree list, with no new engine passes. *)
  let gen_cmds ?(max_steps = default_max_steps) () : S.cmd list G.t =
    let open G.Let_syntax in
    let%bind n = G.int_uniform_inclusive 0 max_steps in
    let rec go state k : S.cmd list G.t =
      if k = 0 then return []
      else
        let%bind cmd = S.arb_cmd state in
        let%bind rest = go (S.next_state cmd state) (k - 1) in
        return (cmd :: rest)
    in
    go S.init_state n

  type outcome =
    | Ok_run
    (* Defensive only: should not trigger if [arb_cmd] respects
       [precond], since [gen_cmds] always draws from the CURRENT
       state. Kept distinct from [Postcond_failed] for diagnosis. *)
    | Precond_violated of int * S.cmd
    | Postcond_failed of int * S.cmd
    | Invariant_failed of int * S.cmd option

  let sexp_of_outcome = function
    | Ok_run -> Sexp.Atom "Ok_run"
    | Precond_violated (i, c) ->
      Sexp.List [ Sexp.Atom "Precond_violated"; sexp_of_int i; S.sexp_of_cmd c ]
    | Postcond_failed (i, c) ->
      Sexp.List [ Sexp.Atom "Postcond_failed"; sexp_of_int i; S.sexp_of_cmd c ]
    | Invariant_failed (i, c) ->
      Sexp.List
        [ Sexp.Atom "Invariant_failed"
        ; sexp_of_int i
        ; sexp_of_option S.sexp_of_cmd c
        ]

  (* Execute the whole command list against a fresh [sut], checking
     [precond]/[postcond]/[invariant] as we go. A [precond] violation is
     a specification error: [gen_cmds] draws each command from the current
     state, so a well-formed [arb_cmd] must not produce one. Return the
     dedicated diagnostic outcome instead of silently skipping the command;
     callers can also supply command lists directly to [run_cmds]. *)
  let run_cmds (cmds : S.cmd list) : outcome =
    let sut = S.init_sut () in
    Exn.protect
      ~finally:(fun () -> S.cleanup sut)
      ~f:(fun () ->
        let rec go state idx = function
          | [] -> Ok_run
          | cmd :: rest ->
            if not (S.precond cmd state) then Precond_violated (idx, cmd)
            else begin
              let res = S.run cmd sut in
              if not (S.postcond cmd state res) then Postcond_failed (idx, cmd)
              else begin
                let state' = S.next_state cmd state in
                if not (S.invariant state' sut) then
                  Invariant_failed (idx, Some cmd)
                else go state' (idx + 1) rest
              end
            end
        in
        if not (S.invariant S.init_state sut) then Invariant_failed (0, None)
        else go S.init_state 0 cmds)

  let test (cmds : S.cmd list) : bool =
    match run_cmds cmds with
    | Ok_run -> true
    | Precond_violated _ | Postcond_failed _ | Invariant_failed _ -> false
end

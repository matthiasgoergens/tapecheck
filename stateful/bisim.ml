(* Bisimulation testing: two implementations of the same API, checked
   against each other by running the SAME generated operation sequence
   through both and comparing observable results one call at a time.
   Ported from the idea Yaron Minsky described Jane Street's internal
   base_quickcheck extension doing in 2022 ("What the interns have
   wrought, 2022 edition": "have two different implementations of the
   same API, and... test them against each other... you actually need
   to call sequences of operations to build up the values that you're
   operating on") and shaped by reading Jane Street's hand-rolled
   equivalents, [core/test/test_doubly_linked_bisimulation.ml] and
   [base_test/test/test_queue.ml]: a slow, obviously-correct reference
   implementation checked step-by-step against a fast one. Built on the
   same [gen_cmds]-is-a-state-dependent-bind-generator idea as
   [Stateful] (see stateful.ml's module doc comment) for the same
   shrink-coherence reason: deleting an earlier operation re-derives
   later ones against the ACTUAL post-deletion state on replay.

   The mutual-raise design below exists specifically because of a bug
   class Jane Street's own hand-rolled version has: in
   [test_doubly_linked_bisimulation.ml] (janestreet/core, default
   branch, lines ~615-616), a shared predicate helper has a typo,
   [n mod 0] where [n mod 2] was meant, which raises
   [Division_by_zero] unconditionally; both the real [Doubly_linked]
   and the hand-written [Foil] reference call it identically, so both
   sides raise, and the file's own comparison (line ~307,
   [| Error _, Error _ -> raise Both_raised], discarded at line ~661)
   treats mutual raising as nothing to look at. Five operations
   ([Exists], [Filter_inplace], [For_all], [Find_elt], [Find]) have
   therefore gone untested since around 2020, while the ASYMMETRIC
   cases (one side raises, the other returns) were and are checked
   correctly. The fix here is two-fold: make the "compare mutual
   raises, or don't" decision an explicit, named, inspectable argument
   ([on_both_raised]) rather than an implicit match arm, and COUNT how
   often agreement happens only that way, so a comparison that is
   silently starved of real return-value checks announces itself (see
   [most_steps_agreed_only_by_raising] below) instead of quietly
   passing forever. *)

open! Base

type 'a outcome =
  | Returned of 'a
  | Raised of exn

let capture (f : unit -> 'a) : 'a outcome =
  match f () with
  | v -> Returned v
  | exception exn -> Raised exn

module type Spec = sig
  type state (* pure model, threaded through generation/precond only *)
  type left (* the slow, obviously-correct reference implementation *)
  type right (* the fast implementation under test *)
  type cmd
  type res (* the comparable projection of one call's result *)

  val init_state : state
  val init_left : unit -> left
  val init_right : unit -> right
  val cleanup_left : left -> unit
  val cleanup_right : right -> unit

  val arb_cmd : state -> cmd Base_quickcheck.Generator.t
  val precond : cmd -> state -> bool
  val next_state : cmd -> state -> state

  val run_left : cmd -> left -> res
  val run_right : cmd -> right -> res
  val equal_res : res -> res -> bool

  val sexp_of_cmd : cmd -> Sexp.t
  val sexp_of_res : res -> Sexp.t
end

let default_max_steps = 50

(* Per-step bookkeeping, meant to be created once and threaded through
   every call the tape engine makes (generation AND every shrink
   replay) so the ratios reflect the whole run, not one case. Read
   after a run with [most_steps_agreed_only_by_raising]. Once
   engine/tape_health.ml (branch statistics-and-health) merges, these
   three counters are exactly its shape and can feed its health-check
   registry directly instead of the standalone check below. *)
type stats =
  { mutable agree : int
  ; mutable agreed_by_raising : int
  ; mutable disagree : int
  }

let create_stats () = { agree = 0; agreed_by_raising = 0; disagree = 0 }

let sexp_of_stats (s : stats) : Sexp.t =
  [%sexp_of: (string * int) list]
    [ "agree", s.agree
    ; "agreed_by_raising", s.agreed_by_raising
    ; "disagree", s.disagree
    ]

(* Hypothesis-style health check (the [filter_too_much] analogue for
   bisimulation, outreach/hypothesis-inventory.md item 3): fires when
   most agreements are only "both sides raised, and the exceptions
   were judged equal under [on_both_raised]" rather than an actual
   returned-value comparison -- the exact blind spot described in the
   module doc comment above. A run where this fires is not wrong, but
   it is probably not testing what its author thinks it's testing. *)
let most_steps_agreed_only_by_raising ?(threshold = 0.5) (s : stats) : bool =
  let total = s.agree + s.agreed_by_raising + s.disagree in
  total > 0
  && Float.( >= )
       (Float.of_int s.agreed_by_raising /. Float.of_int total)
       threshold

module Make (S : Spec) = struct
  (* Same state-dependent, length-prefixed bind shape as
     Stateful.Make.gen_cmds; see stateful.ml's module doc comment for
     why this is what gives the tape its shrink-coherence advantage. *)
  let gen_cmds ?(max_steps = default_max_steps) () : S.cmd list Base_quickcheck.Generator.t =
    let open Base_quickcheck.Generator.Let_syntax in
    let%bind n = Base_quickcheck.Generator.int_uniform_inclusive 0 max_steps in
    let rec go state k : S.cmd list Base_quickcheck.Generator.t =
      if k = 0 then return []
      else
        let%bind cmd = S.arb_cmd state in
        let%bind rest = go (S.next_state cmd state) (k - 1) in
        return (cmd :: rest)
    in
    go S.init_state n

  type divergence =
    | Returned_vs_returned of S.res * S.res
    | Left_raised_right_returned of exn * S.res
    | Left_returned_right_raised of S.res * exn
    | Both_raised_but_differ of exn * exn

  type outcome =
    | Ok_run
    | Diverged of int * S.cmd * divergence

  let sexp_of_divergence = function
    | Returned_vs_returned (a, b) ->
      Sexp.List
        [ Sexp.Atom "Returned_vs_returned"; S.sexp_of_res a; S.sexp_of_res b ]
    | Left_raised_right_returned (el, b) ->
      Sexp.List
        [ Sexp.Atom "Left_raised_right_returned"
        ; Sexp.Atom (Exn.to_string el)
        ; S.sexp_of_res b
        ]
    | Left_returned_right_raised (a, er) ->
      Sexp.List
        [ Sexp.Atom "Left_returned_right_raised"
        ; S.sexp_of_res a
        ; Sexp.Atom (Exn.to_string er)
        ]
    | Both_raised_but_differ (el, er) ->
      Sexp.List
        [ Sexp.Atom "Both_raised_but_differ"
        ; Sexp.Atom (Exn.to_string el)
        ; Sexp.Atom (Exn.to_string er)
        ]

  let sexp_of_outcome = function
    | Ok_run -> Sexp.Atom "Ok_run"
    | Diverged (i, c, d) ->
      Sexp.List
        [ Sexp.Atom "Diverged"; sexp_of_int i; S.sexp_of_cmd c
        ; sexp_of_divergence d
        ]

  (* Execute [cmds] against a fresh [left]/[right] pair, one command at
     a time, comparing every call's outcome.

     [on_both_raised] projects an exception to something comparable
     BEFORE judging two mutual raises as agreement. This names the
     decision a bare [Error _, Error _ -> ()] leaves implicit and
     unexaminable: that IS already a projection, just the maximally lax
     one ([fun _ -> ()], everything raised is "the same"), and writing
     it as a match arm hides that a decision was made at all. The
     default, [Base.Exn.to_string], is strict in the sense the design
     brief asks for -- it distinguishes different exception
     constructors, and (when a sexp converter is registered, as it is
     for most Base/stdlib exceptions) different payloads, so
     [Invalid_argument "a"] and [Invalid_argument "b"] disagree by
     default. It is deliberately NOT maximally strict: it cannot
     distinguish two raises of the exact same exception value from
     different call sites (nor would raw structural/physical equality
     on [exn] help there), and it will not by itself have caught the
     janestreet/core typo above (both sides raise the literal same
     nullary [Division_by_zero]) -- that is what [stats] plus
     [most_steps_agreed_only_by_raising] are for: they make "how often
     did this shortcut fire" visible and checkable regardless of how
     strict the projection is. Callers who want the old, fully lax
     behaviour can pass [~on_both_raised:(fun _ -> "")] explicitly; the
     point of this parameter is that such a choice is now visible at
     the call site instead of buried in a match arm. *)
  let run_cmds ?(on_both_raised = Exn.to_string) ?stats (cmds : S.cmd list) :
      outcome =
    let stats = match stats with Some s -> s | None -> create_stats () in
    let left = S.init_left () in
    let right = S.init_right () in
    Exn.protect
      ~finally:(fun () ->
        S.cleanup_left left;
        S.cleanup_right right)
      ~f:(fun () ->
        let rec go state idx = function
          | [] -> Ok_run
          | cmd :: rest ->
            if not (S.precond cmd state) then go state (idx + 1) rest
            else begin
              let outcome_l = capture (fun () -> S.run_left cmd left) in
              let outcome_r = capture (fun () -> S.run_right cmd right) in
              let disagreement =
                match (outcome_l, outcome_r) with
                | Returned a, Returned b ->
                  if S.equal_res a b then None
                  else Some (Returned_vs_returned (a, b))
                | Raised el, Returned b -> Some (Left_raised_right_returned (el, b))
                | Returned a, Raised er -> Some (Left_returned_right_raised (a, er))
                | Raised el, Raised er ->
                  if String.equal (on_both_raised el) (on_both_raised er) then begin
                    stats.agreed_by_raising <- stats.agreed_by_raising + 1;
                    None
                  end
                  else Some (Both_raised_but_differ (el, er))
              in
              match disagreement with
              | Some d ->
                stats.disagree <- stats.disagree + 1;
                Diverged (idx, cmd, d)
              | None ->
                (match (outcome_l, outcome_r) with
                 | Returned _, Returned _ -> stats.agree <- stats.agree + 1
                 | _ -> () (* Agreed_by_raising already counted above *));
                go (S.next_state cmd state) (idx + 1) rest
            end
        in
        go S.init_state 0 cmds)

  let test ?on_both_raised ?stats (cmds : S.cmd list) : bool =
    match run_cmds ?on_both_raised ?stats cmds with
    | Ok_run -> true
    | Diverged _ -> false
end

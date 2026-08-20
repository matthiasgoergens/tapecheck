(** Stateful bisimulation testing. *)

open! Base

module type Spec = sig
  type state
  type left
  type right
  type cmd
  type res

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

(** Mutable counters accumulated across generation and shrink replays. *)
type stats

type stats_snapshot =
  { agree : int
  ; agreed_by_raising : int
  ; disagree : int
  }

val create_stats : unit -> stats
val snapshot : stats -> stats_snapshot
val sexp_of_stats : stats -> Sexp.t

val most_steps_agreed_only_by_raising : ?threshold:float -> stats -> bool

type warning =
  { op : string
  ; steps : int
  ; agreed_by_raising : int
  ; ratio : float
  }

val sexp_of_warning : warning -> Sexp.t

val ops_agreeing_only_by_raising
  :  ?threshold:float
  -> ?min_steps:int
  -> ?expected_raising:string list
  -> stats
  -> warning list

val ops_undersampled
  :  ?threshold:float
  -> ?min_steps:int
  -> ?expected_raising:string list
  -> stats
  -> warning list

val label_resolution_is_degenerate : stats -> bool

val health_report
  :  ?threshold:float
  -> ?min_steps:int
  -> ?expected_raising:string list
  -> stats
  -> string option

module Make (S : Spec) : sig
  val gen_cmds
    :  ?max_steps:int
    -> unit
    -> S.cmd list Base_quickcheck.Generator.t

  type divergence =
    | Returned_vs_returned of S.res * S.res
    | Left_raised_right_returned of exn * S.res
    | Left_returned_right_raised of S.res * exn
    | Both_raised_but_differ of exn * exn

  type outcome =
    | Ok_run
    | Diverged of int * S.cmd * divergence

  val sexp_of_divergence : divergence -> Sexp.t
  val sexp_of_outcome : outcome -> Sexp.t

  val run_cmds
    :  ?on_both_raised:(exn -> string)
    -> ?op_label:(S.cmd -> string)
    -> ?stats:stats
    -> S.cmd list
    -> outcome

  val test
    :  ?on_both_raised:(exn -> string)
    -> ?op_label:(S.cmd -> string)
    -> ?stats:stats
    -> S.cmd list
    -> bool

  val with_health
    :  ?on_both_raised:(exn -> string)
    -> ?op_label:(S.cmd -> string)
    -> ?threshold:float
    -> ?min_steps:int
    -> ?expected_raising:string list
    -> ?health:bool
    -> ?report:(string -> unit)
    -> ((S.cmd list -> bool) -> 'a)
    -> 'a * stats
end

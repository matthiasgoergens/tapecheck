(** Stateful model testing with state-dependent command generation. *)

open! Base

module Bundle : sig
  (** Newest-first values produced by earlier commands. *)
  type 'a t = 'a list

  val empty : 'a t
  val push : 'a t -> 'a -> 'a t
  val is_empty : 'a t -> bool
  val length : 'a t -> int
  val gen_index : 'a t -> int Base_quickcheck.Generator.t
  val get : 'a t -> int -> 'a
  val remove : 'a t -> int -> 'a t
end

(** Select uniformly among the generators whose guards are true. Raises when
    no rule is enabled. *)
val rules
  :  (bool * 'cmd Base_quickcheck.Generator.t) list
  -> 'cmd Base_quickcheck.Generator.t

module type Spec = sig
  type state
  type sut
  type cmd
  type res

  val init_state : state
  val init_sut : unit -> sut
  val cleanup : sut -> unit
  val arb_cmd : state -> cmd Base_quickcheck.Generator.t
  val precond : cmd -> state -> bool
  val next_state : cmd -> state -> state
  val run : cmd -> sut -> res
  val postcond : cmd -> state -> res -> bool
  val invariant : state -> sut -> bool
  val sexp_of_cmd : cmd -> Sexp.t
end

module Make (S : Spec) : sig
  val gen_cmds
    :  ?max_steps:int
    -> unit
    -> S.cmd list Base_quickcheck.Generator.t

  type outcome =
    | Ok_run
    | Precond_violated of int * S.cmd
    | Postcond_failed of int * S.cmd
    | Invariant_failed of int * S.cmd option

  val sexp_of_outcome : outcome -> Sexp.t
  (** Run a command trace against a fresh system under test. A command whose
      precondition does not hold produces [Precond_violated]; generated traces
      should never do so when [Spec.arb_cmd] is implemented correctly. *)
  val run_cmds : S.cmd list -> outcome
  val test : S.cmd list -> bool
end

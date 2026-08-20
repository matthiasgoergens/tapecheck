(** Health checks for property runs. *)

open! Base

type t =
  | Filter_too_much
  | Too_slow
  | Data_too_large
  | Large_base_example
  | Trivial_only
[@@deriving sexp_of]

val equal : t -> t -> bool
val to_string : t -> string

(** Mutable health-check state shared across every generation phase of one
    logical test run. Its counters are deliberately hidden. *)
type state

val create : unit -> state
val is_closed : state -> bool
val has_checked_base_example : state -> bool

(** Checks which have fired, most recent first. The returned list is an
    immutable snapshot. *)
val fired : state -> t list

val record
  :  state
  -> suppress:t list
  -> status:[ `Valid | `Invalid ]
  -> choices:int
  -> generate_time:float
  -> unit

val maybe_check_large_base_example
  :  state
  -> suppress:t list
  -> choices:int
  -> unit

val record_observation : state -> suppress:t list -> string -> unit

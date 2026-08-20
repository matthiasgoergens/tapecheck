(** Per-case assumptions and event statistics.

    User-facing code normally reaches [assume] and [event] through
    {!Tape_test}; the remaining declarations are shared with the engine. *)

open! Base

exception Invalid_example

(** [assume condition] discards the current generated case when [condition]
    is false. Outside a Tapecheck test evaluation, [Invalid_example]
    propagates normally. *)
val assume : bool -> unit

type verdict =
  | Case_passed
  | Case_failed
  | Case_invalid

(** Attach an event label to the current case. Repeated events are counted. *)
val event : ?payload:string -> string -> unit

(** {2 Engine integration}

    These operations delimit one test evaluation and transfer its events into
    a run-wide aggregate. They are public at the OCaml module boundary because
    [Tape_engine] is currently an unwrapped sibling module; ordinary users
    should not need them. *)

val begin_case : unit -> unit
val merge_current_events_into : (string, int) Hashtbl.t -> unit

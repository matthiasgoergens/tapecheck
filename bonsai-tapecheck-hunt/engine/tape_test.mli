(** Choice-tape property-test runner for [base_quickcheck] generators.

    The five ordinary entry points are source-compatible with
    [Base_quickcheck.Test], but the semantics are not identical: Tapecheck
    ignores [Config.shrink_count] and its runner uses recorded, edge-biased
    generation followed by tape shrinking. [with_sample] and
    [with_sample_exn] retain Base Quickcheck's stock sampling sequence. *)

open! Base

module Config = Base_quickcheck.Test.Config
module type S = Base_quickcheck.Test.S

exception Flaky_test of string

val default_config : Config.t

val with_sample
  :  f:('a Sequence.t -> unit Or_error.t)
  -> ?config:Config.t
  -> ?examples:'a list
  -> 'a Base_quickcheck.Generator.t
  -> unit Or_error.t

val with_sample_exn
  :  f:('a Sequence.t -> unit)
  -> ?config:Config.t
  -> ?examples:'a list
  -> 'a Base_quickcheck.Generator.t
  -> unit

(** Discard the current case unless [condition] holds. *)
val assume : bool -> unit

(** Attach a label, optionally with a payload, to the current case's
    statistics. *)
val event : ?payload:string -> string -> unit

type report_level =
  [ `Silent
  | `Summary
  | `Full
  ]

(** Statistics accumulated by a run. The mutable engine representation is
    hidden; call [snapshot] to inspect a stable immutable value. *)
module Stats : sig
  type t

  type snapshot = Tape_engine.stats_snapshot =
    { replays : int
    ; tests : int
    ; misaligns : int
    ; cases_valid : int
    ; cases_invalid : int
    ; cases_failed : int
    ; shrink_discards : int
    ; events : (string * int) list
    ; generate_time : float
    ; run_time : float
    ; shrink_time : float
    ; warnings : string list
    }

  val create : unit -> t
  val snapshot : t -> snapshot
  val summary_line : t -> string
  val to_string_hum : t -> string
end

(** Run a property and retain its typed error value on failure. *)
val result
  :  f:('a -> (unit, 'e) Result.t)
  -> ?config:Config.t
  -> ?examples:'a list
  -> ?regressions:string
  -> ?realign:Tape_engine.realign
  -> ?explain:bool
  -> ?explain_budget:int
  -> ?max_shrinks:int
  -> ?max_shrink_seconds:float option
  -> ?report:report_level
  -> ?suppress_health_check:Tape_health.t list
  -> ?db:Tape_db.t
  -> ?db_key:string
  -> ?stats:Stats.t
  -> (module S with type t = 'a)
  -> (unit, 'a * 'e) Result.t

(** Run a property expressed with [Or_error]. *)
val run
  :  f:('a -> unit Or_error.t)
  -> ?config:Config.t
  -> ?examples:'a list
  -> ?regressions:string
  -> ?realign:Tape_engine.realign
  -> ?explain:bool
  -> ?explain_budget:int
  -> ?max_shrinks:int
  -> ?max_shrink_seconds:float option
  -> ?report:report_level
  -> ?suppress_health_check:Tape_health.t list
  -> ?db:Tape_db.t
  -> ?db_key:string
  -> ?stats:Stats.t
  -> (module S with type t = 'a)
  -> unit Or_error.t

(** Run a property which reports failure by raising. *)
val run_exn
  :  f:('a -> unit)
  -> ?config:Config.t
  -> ?examples:'a list
  -> ?regressions:string
  -> ?realign:Tape_engine.realign
  -> ?explain:bool
  -> ?explain_budget:int
  -> ?max_shrinks:int
  -> ?max_shrink_seconds:float option
  -> ?report:report_level
  -> ?suppress_health_check:Tape_health.t list
  -> ?db:Tape_db.t
  -> ?db_key:string
  -> ?stats:Stats.t
  -> (module S with type t = 'a)
  -> unit

(** Continue shrinking from a hexadecimal tape printed by a truncated run. The
    supplied [size] must match the recording context. *)
val resume_result
  :  f:('a -> (unit, 'e) Result.t)
  -> ?size:int
  -> ?regressions:string
  -> ?realign:Tape_engine.realign
  -> ?explain:bool
  -> ?explain_budget:int
  -> ?max_shrinks:int
  -> ?max_shrink_seconds:float option
  -> tape:string
  -> (module S with type t = 'a)
  -> (unit, 'a * 'e) Result.t

val resume_run
  :  f:('a -> unit Or_error.t)
  -> ?size:int
  -> ?regressions:string
  -> ?realign:Tape_engine.realign
  -> ?explain:bool
  -> ?explain_budget:int
  -> ?max_shrinks:int
  -> ?max_shrink_seconds:float option
  -> tape:string
  -> (module S with type t = 'a)
  -> unit Or_error.t

val resume_run_exn
  :  f:('a -> unit)
  -> ?size:int
  -> ?regressions:string
  -> ?realign:Tape_engine.realign
  -> ?explain:bool
  -> ?explain_budget:int
  -> ?max_shrinks:int
  -> ?max_shrink_seconds:float option
  -> tape:string
  -> (module S with type t = 'a)
  -> unit

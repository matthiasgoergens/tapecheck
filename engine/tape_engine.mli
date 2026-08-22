(** The choice-tape runner.

    This interface is intentionally the first, conservative boundary around
    the runner.  Implementation helpers remain private; the diagnostic
    entry points below are retained for the repository's experiments while
    they are being split into a separate support library. *)

open! Base

type 'a failure =
  { minimal : 'a
  ; original : 'a
  ; attempts : int
  ; choices : Tape.choice array
  ; image : Tape.image
  ; trail : Tape.image list
  ; converged : bool
  }

type 'a result =
  | Passed of { cases : int }
  | Failed of 'a failure

type realign = [ `Consume | `Freeze | `Both ]

type stats

type stats_snapshot =
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

val no_stats : unit -> stats
val stats_snapshot : stats -> stats_snapshot

module For_tape_test : sig
  (** Account for cases run outside [run], such as explicit examples and
      persisted regressions handled by [Tape_test]. This module is an
      implementation seam, not part of the ordinary runner API. *)
  val record_valid_case : stats -> unit
  val record_invalid_case : stats -> unit
  val record_failed_case : stats -> unit
end

(** Run generation and shrinking directly. With [domains > 1], search cases
    and shrink proposals are evaluated in a worker pool, but generation-phase
    events, health checks, observations, timings, exhaustion detection, and
    correlated-value generation are currently unavailable. Pass/discard counts
    and shrink replay accounting are retained. *)
val run
  :  ?seed:int
  -> ?count:int
  -> ?size:int
  -> ?budget:int
  -> ?max_seconds:float option
  -> ?max_shrinks:int
  -> ?max_stall:int option
  -> ?max_pass_failures:int option
  -> ?domains:int
  -> ?realign:realign
  -> ?stats:stats
  -> ?health:Tape_health.state
  -> ?suppress_health_check:Tape_health.t list
  -> ?observe:('a -> string)
  -> 'a Base_quickcheck.Generator.t
  -> test:('a -> bool)
  -> 'a result

val resume
  :  ?size:int
  -> ?budget:int
  -> ?max_seconds:float option
  -> ?max_shrinks:int
  -> ?max_stall:int option
  -> ?max_pass_failures:int option
  -> ?domains:int
  -> ?realign:realign
  -> ?stats:stats
  -> 'a Base_quickcheck.Generator.t
  -> test:('a -> bool)
  -> Tape.image
  -> 'a result

val replay_image_and_apply
  :  'a Base_quickcheck.Generator.t
  -> ?size:int
  -> Tape.image
  -> f:('a -> 'r)
  -> 'a * 'r

val image_trivialized : Tape.image -> Tape.image

val check_generator_determinism
  :  ?replays:int
  -> gen:'a Base_quickcheck.Generator.t
  -> size:int
  -> test:('a -> bool)
  -> Tape.image
  -> bool

val nondeterminism_warning : string

val stats_summary_line : stats -> string
val stats_to_string_hum : stats -> string

val run_with_db
  :  db:Tape_db.t
  -> db_key:string
  -> run_fresh:(unit -> 'a result)
  -> resume_from:(Tape.image -> 'a result)
  -> image_of:('a result -> Tape.image option)
  -> 'a result

val run_target
  :  ?seed:int
  -> ?size:int
  -> ?max_improvements:int
  -> ?budget:int
  -> ?realign:realign
  -> ?stats:stats
  -> 'a Base_quickcheck.Generator.t
  -> objective:('a -> float)
  -> 'a * float * int

type origin =
  { exn_name : string
  ; loc : string
  }

type 'a failure_report =
  { fr_origin : origin
  ; fr_minimal : 'a
  ; fr_image : Tape.image
  ; fr_attempts : int
  }

val sexp_of_origin : origin -> Sexp.t

val run_multi
  :  ?seed:int
  -> ?count:int
  -> ?size:int
  -> ?budget:int
  -> ?realign:realign
  -> ?stats:stats
  -> 'a Base_quickcheck.Generator.t
  -> test:('a -> unit)
  -> 'a failure_report list

module For_explain : sig
  (** Internal coordination surface used by [Tape_explain]. *)
  val replay_fresh_seed : int
  val seg_count : Tape.image -> int
  val seg_get : Tape.image -> int -> Tape.choice array
  val seg_set : Tape.image -> int -> Tape.choice array -> Tape.image
  val with_choice : Tape.choice array -> int -> Tape.choice -> Tape.choice array

  val run_and_test
    :  tape:Tape.t
    -> gen:'a Base_quickcheck.Generator.t
    -> size:int
    -> seed:int
    -> test:('a -> bool)
    -> 'a * Tape_stats.verdict option * Tape.output
end

module Diagnostics : sig
  (** Unstable measurements and structural helpers for repository experiments. *)
  val reassemble_permutation
    :  n:int
    -> parent_start:int
    -> parent_stop:int
    -> children:(int * int) list
    -> order:int list
    -> int array option

  val last_pass_costs : unit -> (string * int) list
  val last_duplicate_stats : unit -> int * int
  val last_greedy_cost : unit -> int
  val last_length_repair : unit -> int * int
  val last_computed_repair : unit -> int * int
  val last_shape : unit -> int * int * int * int * int * int
end

val replay
  :  'a Base_quickcheck.Generator.t
  -> ?size:int
  -> Tape.choice array
  -> 'a

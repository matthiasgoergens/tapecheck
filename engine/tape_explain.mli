(** Bounded free-variation analysis for a shrunk failure. *)

open! Base

type 'a outcome =
  | Varies of { examples : 'a list }
  | No_variation_found
  | No_alternative_possible

type 'a choice_report =
  { seg : int
  ; stream_key : Tape.key
  ; index : int
  ; original : Tape.choice
  ; outcome : 'a outcome
  ; tries : int
  }

type 'a t =
  { choices : 'a choice_report list
  ; attempts_per_choice : int
  ; used : int
  ; complete : bool
  }

val default_attempts_per_choice : int

val analyze
  :  gen:'a Base_quickcheck.Generator.t
  -> size:int
  -> test:('a -> bool)
  -> ?attempts_per_choice:int
  -> ?trail:Tape.image list
  -> Tape.image
  -> 'a t

val to_string_hum : sexp_of:('a -> Sexp.t) -> 'a t -> string

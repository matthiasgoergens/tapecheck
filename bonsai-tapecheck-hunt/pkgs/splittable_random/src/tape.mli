(** Typed choice-tape recording and replay. *)

type choice =
  | Integer of
      { value : int64
      ; lo : int64
      ; hi : int64
      }
  | Float of
      { value : float
      ; lo : float
      ; hi : float
      }
  | Bool of bool
  | Marker

type key_elt =
  | Split of int
  | Salt of int

type key = key_elt list

val root : key
val compare_key : key -> key -> int

type policy =
  | Consume
  | Freeze

type image =
  { main : choice array
  ; streams : (key * choice array) array
  }

type span =
  { stream : key
  ; label : int
  ; deletable : bool
  ; discarded : bool
  ; descendable : bool
  ; reorderable : bool
  ; id : int
  ; parent : int option
  ; depth : int
  ; start : int
  ; stop : int
  }

val image_of_main : choice array -> image

(** Mutable recording/replay state. Its stream tables and cursors are private. *)
type t

type output =
  { image : image
  ; choices : choice array
  ; overrun : bool
  ; misaligned : bool
  ; spans : span array
  }

val create : unit -> t
val start_recording : t -> unit
val start_replay_image : ?policy:policy -> t -> image -> unit
val start_replay : ?policy:policy -> t -> choice array -> unit
val finish : t -> output
val overrun_now : t -> bool

val on_span_start
  :  t
  -> stream:key
  -> label:int
  -> deletable:bool
  -> discardable:bool
  -> descendable:bool
  -> reorderable:bool
  -> unit

val on_span_stop
  :  t
  -> stream:key
  -> deletable:bool
  -> discardable:bool
  -> descendable:bool
  -> reorderable:bool
  -> discarded:bool
  -> unit

val draw_int
  :  ?stream:key
  -> t
  -> lo:int64
  -> hi:int64
  -> sample:(lo:int64 -> hi:int64 -> int64)
  -> int64

val draw_float
  :  ?stream:key
  -> t
  -> lo:float
  -> hi:float
  -> sample:(lo:float -> hi:float -> float)
  -> float

val draw_bool
  :  ?stream:key
  -> ?forced:bool
  -> t
  -> sample:(unit -> bool)
  -> bool

val on_split : t -> stream:key -> key
val on_perturb : t -> stream:key -> salt:int -> key option

val serialize_image : image -> string
val deserialize_image : string -> image option
val serialize : choice array -> string
val deserialize : string -> choice array option

val clamp_int64 : int64 -> lo:int64 -> hi:int64 -> int64
val clamp_float : float -> lo:float -> hi:float -> float

module Domain : sig
  val target : choice -> choice
  val at_target : choice -> bool
  val compare : choice -> choice -> int
  val equal : choice -> choice -> bool
  val compare_structural : choice -> choice -> int
end

val equal_choices : choice array -> choice array -> bool
val compare_shortlex : choice array -> choice array -> int
val image_size : image -> int
val compare_image : image -> image -> int
val equal_image : image -> image -> bool

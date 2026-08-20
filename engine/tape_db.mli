(** Persistent storage for shrunk failure tapes. *)

type on_write_error =
  | Warn
  | Silent
  | Raise

type t

(** Create a database rooted at [dir].

    [replay] controls reads and [record] controls writes and removals. [Warn]
    reports the first write failure and then allows the test run to continue. *)
val create
  :  dir:string
  -> ?replay:bool
  -> ?record:bool
  -> ?on_write_error:on_write_error
  -> unit
  -> t

(** Convert an arbitrary property key to its collision-resistant on-disk
    filename. Exposed so database tooling and tests can locate entries without
    duplicating the encoding. *)
val key_to_filename : string -> string

(** Load the stored image and the ambient generation size recorded with it.
    Legacy entries may return [None] for the size. Invalid or unreadable cache
    entries are treated as absent. *)
val load_sized : t -> key:string -> (Tape.image * int option) option

(** Load only the stored image. *)
val load : t -> key:string -> Tape.image option

(** Atomically store an image. Omitting [size] writes the legacy sentinel and
    therefore loads back as [None]. Write failures follow [on_write_error]. *)
val save : t -> key:string -> ?size:int -> Tape.image -> unit

(** Remove a stored entry when recording is enabled. *)
val remove : t -> key:string -> unit

(* Automatic failure database: save the tape of a failing run, replay it
   first next time.

   Ported from Hypothesis's ExampleDatabase / Phase.reuse. Matthias
   named this as the feature that mattered most to him in practice with
   Hypothesis -- "makes subsequent runs automatically very quick" --
   which is not something reading the source tells you. That is the
   reason it jumped the queue ahead of the other mining targets, and it
   is worth recording, because the source makes it look like a
   convenience rather than the thing users notice.

   The mechanism behind "very quick": on a re-run the saved failing tape
   is replayed BEFORE generating anything. If the bug is still there it
   reproduces on call one instead of after a search. If it has been
   fixed, the entry is deleted, so a fixed bug costs one replay once and
   nothing thereafter. Both halves matter -- a database that only ever
   grows would slow runs down instead.

   tapecheck already had every piece except the plumbing: Tape has a
   versioned [serialize_image] / [deserialize_image], and the engine has
   [resume] taking an image. What was missing was doing it without the
   user pasting a tape by hand. *)

open! Base

type t =
  { dir : string
  ; replay : bool
        (* Read stored tapes and try them first. Turn off to force a
           fresh search -- e.g. to check that a bug is still findable
           from scratch, which a database otherwise hides. *)
  ; record : bool
        (* Write tapes back. Turn off on a read-only filesystem, or in
           CI where the database would not persist anyway. Writes
           already swallow their errors so a read-only disk cannot break
           a run, but relying on that is not the same as saying so. *)
  }

let create ~dir ?(replay = true) ?(record = true) () = { dir; replay; record }

(* Keys are caller-supplied test names. Sanitised because they end up as
   filenames and a test name is arbitrary text. *)
let key_to_filename (key : string) : string =
  String.map key ~f:(fun c ->
    if Char.is_alphanum c || Char.equal c '-' || Char.equal c '_' then c
    else '_')

let path t ~key = Stdlib.Filename.concat t.dir (key_to_filename key)

let ensure_dir t =
  try if not (Stdlib.Sys.file_exists t.dir) then Unix.mkdir t.dir 0o755
  with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

(* Read the stored tape for [key], if any. A file that fails to parse is
   treated as absent rather than fatal: the database is a cache, and a
   format change or a truncated write must never break a test run. *)
let load t ~key : Tape.image option =
  if not t.replay then None
  else
  let file = path t ~key in
  if not (Stdlib.Sys.file_exists file) then None
  else begin
    try
      let ic = Stdlib.open_in_bin file in
      let n = Stdlib.in_channel_length ic in
      let s = Stdlib.really_input_string ic n in
      Stdlib.close_in ic;
      Tape.deserialize_image s
    with _ -> None
  end

(* Written via a temporary file and renamed, so a crash mid-write cannot
   leave a half-written tape that the next run would silently treat as
   absent. *)
let save t ~key (img : Tape.image) : unit =
  if not t.record then ()
  else
  try
    ensure_dir t;
    let file = path t ~key in
    let tmp = file ^ ".tmp" in
    let oc = Stdlib.open_out_bin tmp in
    Stdlib.output_string oc (Tape.serialize_image img);
    Stdlib.close_out oc;
    Stdlib.Sys.rename tmp file
  with _ -> ()

let remove t ~key : unit =
  if not t.record then ()
  else
  try
    let file = path t ~key in
    if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file
  with _ -> ()

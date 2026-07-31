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

(* What to do when a write fails -- a read-only filesystem, a full disk,
   a permissions problem.

   [Warn] is the default, deliberately. Swallowing the error silently is
   how this feature quietly stops working: the run still passes, nothing
   is persisted, and the next run is mysteriously slow again with no
   indication why. A database that is silently not saving is worse than
   no database, because you believe you have one. *)
type on_write_error =
  | Warn (* default: proceed, but say so on stderr *)
  | Silent (* proceed quietly -- for when you already know writes fail *)
  | Raise (* treat it as a hard error, e.g. in CI that expects a writable dir *)

type t =
  { dir : string
  ; replay : bool
        (* Read stored tapes and try them first. Turn off to force a
           fresh search -- e.g. to check that a bug is still findable
           from scratch, which a database otherwise hides. *)
  ; record : bool
        (* Whether to attempt writes at all. Off means not even trying,
           which is distinct from trying and failing quietly: on a
           known-read-only filesystem there is nothing to warn about. *)
  ; on_write_error : on_write_error
  ; mutable warned : bool
        (* Warn once per database, not once per failing write. A test
           suite writing on every property would otherwise produce one
           line per test. *)
  }

let create ~dir ?(replay = true) ?(record = true) ?(on_write_error = Warn) () =
  { dir; replay; record; on_write_error; warned = false }

let report_write_error t ~key (e : exn) =
  match t.on_write_error with
  | Silent -> ()
  | Raise ->
    Stdlib.failwith
      (Printf.sprintf "tapecheck: could not write failure tape for %S in %S: %s"
         key t.dir (Stdlib.Printexc.to_string e))
  | Warn ->
    if not t.warned then begin
      t.warned <- true;
      Stdlib.prerr_endline
        (Printf.sprintf
           "tapecheck: could not save the failure tape for %S in %S (%s).\n\
           \  Re-runs will not be able to replay this failure, so they stay \
            slow.\n\
           \  Pass ~record:false if that directory is intentionally \
            unwritable, or\n\
           \  ~on_write_error:Silent to suppress this."
           key t.dir (Stdlib.Printexc.to_string e));
      Stdlib.flush Stdlib.stderr
    end

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
    with e -> report_write_error t ~key e

let remove t ~key : unit =
  if not t.record then ()
  else
    try
      let file = path t ~key in
      if Stdlib.Sys.file_exists file then Stdlib.Sys.remove file
    with e -> report_write_error t ~key e

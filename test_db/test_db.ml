(* Automatic failure replay: does it actually make re-runs quick, and
   does it clean up after a fix?

   Both halves are asserted, because a database that only saves is worse
   than none -- re-runs would get slower, not faster. *)
open Base
module G = Base_quickcheck.Generator

let tmpdir = "/tmp/tapecheck-db-test"

let clean () =
  if Stdlib.Sys.file_exists tmpdir then
    Array.iter (Stdlib.Sys.readdir tmpdir) ~f:(fun f ->
      try Stdlib.Sys.remove (Stdlib.Filename.concat tmpdir f) with _ -> ())

let gen = G.list (G.int_uniform_inclusive 0 1000)
let failing l = List.sum (module Int) l ~f:Fn.id < 100
let passing _ = true

let () =
  clean ();
  let db = Tape_db.create ~dir:tmpdir () in
  let key = "sum_ge_100" in
  let stats () = Tape_engine.no_stats () in

  let fresh ~test () =
    let st = stats () in
    let r = Tape_engine.run gen ~test ~seed:12345 ~count:200 ~size:10 ~stats:st in
    (r, st.Tape_engine.tests)
  in
  let resume_from ~test img =
    let st = stats () in
    let r = Tape_engine.resume gen ~test img ~stats:st in
    (r, st.Tape_engine.tests)
  in

  (* Run 1: no stored tape, full search. *)
  let r1, t1 = fresh ~test:failing () in
  let img1 =
    match r1 with
    | Tape_engine.Failed { image; _ } -> Some image
    | _ -> None
  in
  Stdio.printf "run 1 (cold):        %s, %d test calls\n"
    (match r1 with Tape_engine.Failed _ -> "failed" | _ -> "passed")
    t1;
  Option.iter img1 ~f:(fun img -> Tape_db.save db ~key img);

  (* Run 2: stored tape replayed first. *)
  (match Tape_db.load db ~key with
   | None -> Stdio.printf "FAIL: nothing stored\n"
   | Some img ->
     let r2, t2 = resume_from ~test:failing img in
     Stdio.printf "run 2 (replay):      %s, %d test calls\n"
       (match r2 with Tape_engine.Failed _ -> "failed" | _ -> "passed")
       t2;
     Stdio.printf "  speedup: %.1fx fewer test calls\n"
       (Float.of_int t1 /. Float.of_int (Int.max 1 t2)));

  (* Run 3: the bug is "fixed" -- the stored tape must be discarded. *)
  (match Tape_db.load db ~key with
   | None -> Stdio.printf "FAIL: entry vanished early\n"
   | Some img ->
     let r3, _ = resume_from ~test:passing img in
     (match r3 with
      | Tape_engine.Passed _ ->
        Tape_db.remove db ~key;
        Stdio.printf "run 3 (fixed):       passed, stale entry removed\n"
      | Tape_engine.Failed _ -> Stdio.printf "FAIL: still failing\n"));

  let gone = Option.is_none (Tape_db.load db ~key) in
  (* The two switches Matthias asked for. *)
  let db_norecord = Tape_db.create ~dir:tmpdir ~record:false () in
  let db_noreplay = Tape_db.create ~dir:tmpdir ~replay:false () in
  Option.iter img1 ~f:(fun img -> Tape_db.save db ~key img);
  Tape_db.save db_norecord ~key:"never_written"
    (Option.value_exn img1);
  let record_off_wrote = Option.is_some (Tape_db.load db ~key:"never_written") in
  let replay_off_reads = Option.is_some (Tape_db.load db_noreplay ~key) in
  Stdio.printf "\nVERDICT\n";
  let stored_ok = Option.is_some img1 in
  Stdio.printf "  saved a failing tape:                %b\n" stored_ok;
  Stdio.printf "  replay reproduced without searching: %b\n"
    (match img1 with
     | None -> false
     | Some img -> (
       match fst (resume_from ~test:failing img) with
       | Tape_engine.Failed _ -> true
       | _ -> false));
  Stdio.printf "  stale entry deleted after a fix:     %b\n" gone;
  Stdio.printf "  ~record:false writes nothing:        %b\n"
    (not record_off_wrote);
  Stdio.printf "  ~replay:false reads nothing:         %b\n"
    (not replay_off_reads);
  (* Write-failure policy. An unwritable directory is simulated with a
     path under a regular FILE, so mkdir and open both fail. *)
  let blocked = "/etc/hostname/nope" in
  let warned = ref false in
  let db_warn = Tape_db.create ~dir:blocked () in
  let db_silent = Tape_db.create ~dir:blocked ~on_write_error:Tape_db.Silent () in
  let db_raise = Tape_db.create ~dir:blocked ~on_write_error:Tape_db.Raise () in
  let img = Option.value_exn img1 in
  (* Warn (default) and Silent must both survive; only Raise throws. *)
  (try Tape_db.save db_warn ~key img with _ -> warned := true);
  let warn_survived = not !warned in
  let silent_survived =
    try Tape_db.save db_silent ~key img; true with _ -> false
  in
  let raise_raised =
    try Tape_db.save db_raise ~key img; false with _ -> true
  in
  Stdio.printf "  default Warn survives a bad dir:     %b\n" warn_survived;
  Stdio.printf "  Silent survives a bad dir:           %b\n" silent_survived;
  Stdio.printf "  Raise turns it into an error:        %b\n" raise_raised;
  if not
       (stored_ok && gone
       && (not record_off_wrote)
       && (not replay_off_reads)
       && warn_survived && silent_survived && raise_raised)
  then Stdlib.exit 1;

  (* The 1.3x above understates the feature badly, because that bug is
     found within a handful of generated cases so there is barely any
     search to skip. The saving is proportional to how hard the bug is to
     FIND, which is exactly when you care. Repeat on a rare one. *)
  Stdio.printf "\n--- same measurement on a hard-to-find bug ---\n";
  let hard_gen =
    G.both (G.int_uniform_inclusive 0 300) (G.int_uniform_inclusive 0 300)
  in
  let hard_test (m, n) = abs (m - n) <> 1 in
  let st1 = stats () in
  let hr1 =
    Tape_engine.run hard_gen ~test:hard_test ~seed:7 ~count:200 ~size:10
      ~stats:st1
  in
  (match hr1 with
   | Tape_engine.Failed { image; _ } ->
     let c1 = st1.Tape_engine.tests in
     let st2 = stats () in
     let _ = Tape_engine.resume hard_gen ~test:hard_test image ~stats:st2 in
     let c2 = st2.Tape_engine.tests in
     Stdio.printf "  cold search: %4d test calls\n" c1;
     Stdio.printf "  replay:      %4d test calls  (%.1fx fewer)\n" c2
       (Float.of_int c1 /. Float.of_int (Int.max 1 c2))
   | Tape_engine.Passed _ ->
     Stdio.printf "  (no failure found at this seed)\n")

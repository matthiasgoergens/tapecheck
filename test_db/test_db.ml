(* Automatic failure replay: does it actually make re-runs quick, and
   does it clean up after a fix?

   Both halves are asserted, because a database that only saves is worse
   than none -- re-runs would get slower, not faster. *)
open Base
module G = Base_quickcheck.Generator

(* A private directory under the CURRENT directory, which dune gives
   each test to itself, rather than a predictable path in /tmp.

   The old code used a fixed "/tmp/tapecheck-db-*" and then deleted
   every immediate entry in it. If anything symlinks that path at a
   directory you care about, `dune test` empties it; two checkouts
   testing at once also destroy each other's fixtures. [Unix.mkdir]
   fails if the name already exists, so reaching the body of this
   function means the directory is one WE just made. *)
let private_dir prefix =
  let rec attempt n =
    if n > 100 then failwith ("could not create a private directory: " ^ prefix)
    else
      let path = Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) n in
      match Unix.mkdir path 0o700 with
      | () -> path
      | exception Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (n + 1)
  in
  attempt 0

let remove_dir path =
  (* Only files we wrote live here, and [path] is never a symlink
     because we created it with mkdir. *)
  if Stdlib.Sys.file_exists path then begin
    Array.iter (Stdlib.Sys.readdir path) ~f:(fun f ->
      try Stdlib.Sys.remove (Stdlib.Filename.concat path f) with _ -> ());
    try Unix.rmdir path with _ -> ()
  end

let tmpdir = private_dir "tapecheck-db-test"
let () = Stdlib.at_exit (fun () -> remove_dir tmpdir)

let clean () =
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
  (* Two processes saving the same key must never share a temporary path.
     Synchronise their first write, then repeat enough times to exercise the
     atomic replacement path; [Raise] turns any lost-temp race into a child
     failure instead of a warning. *)
  let race_image =
    match
      Tape_engine.run
        (G.list_with_length G.bool ~length:2_000)
        ~test:(fun _ -> false) ~seed:91 ~count:1 ~budget:0
    with
    | Tape_engine.Failed { image; _ } -> image
    | Tape_engine.Passed _ -> failwith "race fixture did not fail"
  in
  let race_key = "concurrent-save" in
  let race_db = Tape_db.create ~dir:tmpdir ~on_write_error:Tape_db.Raise () in
  let reader, writer = Unix.pipe ~cloexec:true () in
  let spawn_writer () =
    match Unix.fork () with
    | 0 ->
      Unix.close writer;
      let byte = Bytes.create 1 in
      ignore (Unix.read reader byte 0 1 : int);
      Unix.close reader;
      (try
         for i = 1 to 30 do
           Tape_db.save race_db ~key:race_key ~size:i race_image
         done;
         Unix._exit 0
       with _ -> Unix._exit 2)
    | pid -> pid
  in
  let writer_a = spawn_writer () in
  let writer_b = spawn_writer () in
  Unix.close reader;
  ignore (Unix.write_substring writer "xx" 0 2 : int);
  Unix.close writer;
  let child_ok pid =
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED 0 -> true
    | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false
  in
  let concurrent_writes_ok = child_ok writer_a && child_ok writer_b in
  let concurrent_entry_parseable =
    Option.is_some (Tape_db.load_sized race_db ~key:race_key)
  in
  let no_temporary_left =
    Array.for_all (Stdlib.Sys.readdir tmpdir) ~f:(fun name ->
      not (String.is_suffix name ~suffix:".tmp"))
  in
  Stdio.printf "  concurrent same-key writes succeed:  %b\n"
    concurrent_writes_ok;
  Stdio.printf "  concurrent result is complete:       %b\n"
    concurrent_entry_parseable;
  Stdio.printf "  concurrent writes leave no temp:     %b\n"
    no_temporary_left;
  if
    not
      (concurrent_writes_ok && concurrent_entry_parseable
       && no_temporary_left)
  then Stdlib.exit 1;

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
  (* Bound, not computed inside the printf: this was printed and then
     left out of the verdict below, so an entirely unwired replay path
     would still have exited 0. *)
  let replay_reproduced =
    match img1 with
    | None -> false
    | Some img -> (
      match fst (resume_from ~test:failing img) with
      | Tape_engine.Failed _ -> true
      | _ -> false)
  in
  Stdio.printf "  replay reproduced without searching: %b\n" replay_reproduced;
  Stdio.printf "  stale entry deleted after a fix:     %b\n" gone;
  Stdio.printf "  ~record:false writes nothing:        %b\n"
    (not record_off_wrote);
  Stdio.printf "  ~replay:false reads nothing:         %b\n"
    (not replay_off_reads);
  (* Write-failure policy. An unwritable directory is simulated with a
     path under a regular FILE, so mkdir and open both fail.

     The file is one we create in the test's own directory, which dune
     gives each test to itself. This used to be "/etc/hostname/nope",
     which assumes /etc/hostname exists AND is a regular file -- true on
     Linux, not guaranteed anywhere else, and the test would have
     reported a spurious pass on a system where the path simply does not
     exist, because then mkdir fails for a different reason and the
     assertions below still hold. Making the file ourselves means the
     precondition is established rather than assumed. *)
  let blocker = "blocker_not_a_directory" in
  Stdio.Out_channel.write_all blocker ~data:"";
  let blocked = Stdlib.Filename.concat blocker "nope" in
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
  (* The blocker file is ours, so remove it: under dune test it lands in
     the sandbox, but a direct [dune exec] run litters the worktree. *)
  (try Stdlib.Sys.remove blocker with Stdlib.Sys_error _ -> ());
  Stdio.printf "  default Warn survives a bad dir:     %b\n" warn_survived;
  Stdio.printf "  Silent survives a bad dir:           %b\n" silent_survived;
  Stdio.printf "  Raise turns it into an error:        %b\n" raise_raised;
  if not
       (stored_ok && replay_reproduced && gone
       && (not record_off_wrote)
       && (not replay_off_reads)
       && warn_survived && silent_survived && raise_raised)
  then Stdlib.exit 1;

  (* The 1.3x above understates the feature badly, because that bug is
     found within a handful of generated cases so there is barely any
     search to skip. The saving is proportional to how hard the bug is to
     FIND, which is exactly when you care. Repeat on a rare one. *)
  (* Keys that the sanitiser alone would conflate must not share a file.
     Flagged in review: the first fix used a 28-bit Hashtbl.hash, which
     only made collisions unlikely. *)
  let collide_a = Tape_db.key_to_filename "a/b" in
  let collide_b = Tape_db.key_to_filename "a?b" in
  let collide_c = Tape_db.key_to_filename "a b" in
  let distinct =
    (not (String.equal collide_a collide_b))
    && (not (String.equal collide_a collide_c))
    && not (String.equal collide_b collide_c)
  in
  Stdio.printf "  keys \"a/b\", \"a?b\", \"a b\" stay distinct:   %b\n" distinct;
  if not distinct then Stdlib.exit 1;

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
       (Float.of_int c1 /. Float.of_int (Int.max 1 c2));
     (* Asserted, not merely printed. The whole point of the database is
        that the second run is cheap; without this, replay could quietly
        degenerate to a full search and the test would still pass. A
        factor of 4 is well inside the measured 38x and well outside
        anything a working replay would produce. *)
     if c2 * 4 > c1 then begin
       Stdio.printf
         "  FAIL: replay cost %d against a cold search of %d -- replay is \
          not saving work\n"
         c2 c1;
       Stdlib.exit 1
     end
   | Tape_engine.Passed _ ->
     Stdio.printf "  FAIL: no failure found at this seed, so the replay \
                   measurement tested nothing\n";
     Stdlib.exit 1)

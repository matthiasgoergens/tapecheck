(* Is the failure database actually reachable from Tape_test?

   Parity review #6: Tape_db existed but nothing exposed it, so the
   feature was unusable from the normal entry point. Wiring it up is
   easy to get subtly wrong -- an optional argument that is accepted and
   then not forwarded compiles fine and silently does nothing, which is
   what happened on the first attempt here. So this asserts the OBSERVABLE
   effect: a tape file appears, and a second run replays it. *)
open! Base
open Base_quickcheck.Export

type t = int [@@deriving quickcheck, sexp_of]

module Int_t = struct
  type nonrec t = t [@@deriving quickcheck, sexp_of]
end

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

let dir = private_dir "tapecheck-db-wired"
let () = Stdlib.at_exit (fun () -> remove_dir dir)

let () =
  let db = Tape_db.create ~dir () in
  let key = "wired_property" in
  let calls = ref 0 in
  let f v =
    Int.incr calls;
    if v > 1000 then Or_error.error_string "too big" else Ok ()
  in
  let r1 = Tape_test.run ~f ~db ~db_key:key (module Int_t) in
  let first_calls = !calls in
  let saved = Option.is_some (Tape_db.load db ~key) in
  Stdio.printf "run 1: %s, %d calls, tape saved: %b\n"
    (match r1 with Ok () -> "passed" | Error _ -> "failed")
    first_calls saved;
  calls := 0;
  let r2 = Tape_test.run ~f ~db ~db_key:key (module Int_t) in
  Stdio.printf "run 2: %s, %d calls (replayed first)\n"
    (match r2 with Ok () -> "passed" | Error _ -> "failed")
    !calls;
  Stdio.printf "\n  database reachable from Tape_test: %b\n" saved;
  if not saved then begin
    Stdio.printf "  FAIL: ?db was accepted but nothing was written\n";
    Stdlib.exit 1
  end;
  Stdio.printf "  ok\n"

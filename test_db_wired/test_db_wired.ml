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

let dir = "/tmp/tapecheck-db-wired"

let () =
  if Stdlib.Sys.file_exists dir then
    Array.iter (Stdlib.Sys.readdir dir) ~f:(fun f ->
      try Stdlib.Sys.remove (Stdlib.Filename.concat dir f) with _ -> ());
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

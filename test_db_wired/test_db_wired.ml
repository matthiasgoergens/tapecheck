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

module Threshold_t = struct
  type t = int [@@deriving sexp_of]

  let quickcheck_generator =
    Base_quickcheck.Generator.int_uniform_inclusive 0 1_000_000

  let quickcheck_shrinker = Base_quickcheck.Shrinker.int
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
  Stdio.printf "  ok\n";

  (* A database entry is not necessarily converged: it may have been written
     by a run with a small budget. A later [Tape_test] invocation resumes with
     its current budget and must replace the entry with the better image it
     reaches, rather than paying for the same progress on every invocation. *)
  let threshold = 123_457 in
  let truncated_key = "truncated_property" in
  let truncated =
    Tape_engine.run Threshold_t.quickcheck_generator
      ~test:(fun v -> v < threshold) ~seed:4242 ~count:200 ~size:10 ~budget:0
  in
  let truncated_image =
    match truncated with
    | Tape_engine.Passed _ -> failwith "expected the budget-0 fixture to fail"
    | Tape_engine.Failed { image; converged; minimal; _ } ->
      if converged || minimal = threshold
      then failwith "budget-0 fixture was unexpectedly already minimal";
      image
  in
  Tape_db.save db ~key:truncated_key ~size:10 truncated_image;
  let resumed =
    Tape_test.result ~db ~db_key:truncated_key ~max_shrinks:2000
      ~report:`Silent
      ~f:(fun v -> if v < threshold then Ok () else Error "too big")
      (module Threshold_t)
  in
  let rewritten_image, rewritten_size =
    Option.value_exn (Tape_db.load_sized db ~key:truncated_key)
  in
  let rewritten_value, () =
    Tape_engine.replay_image_and_apply Threshold_t.quickcheck_generator
      ~size:10 rewritten_image ~f:(fun _ -> ())
  in
  let resumed_and_rewritten =
    Result.is_error resumed
    && rewritten_value = threshold
    && Option.equal Int.equal rewritten_size (Some 10)
    && Tape.compare_image rewritten_image truncated_image < 0
  in
  Stdio.printf "  resumed improvement written back:     %b\n"
    resumed_and_rewritten;
  if not resumed_and_rewritten then Stdlib.exit 1

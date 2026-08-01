(* Do worker domains actually get released when a test raises?

   Two reviews flagged this. The first found that Pool.shutdown ran only
   on the normal return path. My fix wrapped the shrink phase -- and the
   second review correctly pointed out that the FAILURE SEARCH also runs
   batches on the pool, so a raise during generation still skipped the
   finalizer. Both are now wrapped from pool creation onward.

   Source inspection was all either reviewer could do. This measures it:
   OCaml domains are backed by OS threads, so /proc/self/status Threads:
   is a direct observation of whether they were released. A leak shows
   up as a thread count that never comes back down. *)
open Base

(* /proc is Linux-only. Without this the whole advertised [dune test]
   raises Sys_error on macOS, and CI (Ubuntu only) would never notice.
   A missing /proc must ANNOUNCE that the check did not run: a
   portability skip that reports success is a test that certifies what
   it can no longer see. *)
let have_proc = Stdlib.Sys.file_exists "/proc/self/status"

let threads () =
  let ic = Stdlib.open_in "/proc/self/status" in
  let rec go () =
    match Stdlib.input_line ic with
    | line ->
      if String.is_prefix line ~prefix:"Threads:" then begin
        Stdlib.close_in ic;
        Int.of_string (String.strip (String.subo line ~pos:8))
      end
      else go ()
    | exception End_of_file ->
      Stdlib.close_in ic;
      -1
  in
  go ()

exception Boom

let settle () =
  (* Domain teardown is not instantaneous; give it a moment before
     reading, so a slow release is not mistaken for a leak. *)
  for _ = 1 to 20 do
    Stdlib.Gc.minor ();
    Unix.sleepf 0.02
  done

let run_and_raise ~where ~domains =
  let gen = Base_quickcheck.Generator.list (Base_quickcheck.Generator.int_uniform_inclusive 0 100) in
  let calls = ref 0 in
  try
    let (_ : int list Tape_engine.result) =
      Tape_engine.run gen ~domains ~seed:1 ~count:400 ~size:10 ~test:(fun l ->
        Int.incr calls;
        (* [`Generation] raises before any failure is found; [`Shrink]
           lets a failure through first so the raise lands in the shrink
           phase instead. *)
        match where with
        | `Generation -> if !calls > 30 then raise Boom else true
        | `Shrink ->
          (* Fail early so shrinking starts, then raise unconditionally
             once we are certainly past generation. An earlier version
             gated the raise on the property ALSO holding, and the two
             conditions stopped coinciding, so it silently never fired --
             a reminder that a test whose trigger never fires looks
             exactly like a passing test. *)
          if !calls > 40 then raise Boom
          else List.sum (module Int) l ~f:Fn.id < 100)
    in
    Stdio.printf "       (no raise escaped; %d test calls made)\n" !calls;
    false
  with
  | Boom -> true

let () =
  if not have_proc then begin
    Stdio.printf
      "SKIPPED: /proc/self/status is unavailable on this platform, so the \n\
      \         thread-count observation this test is built on cannot be \n\
      \         made. The pool-leak protection is NOT verified here.\n";
    Stdlib.exit 0
  end;
  let baseline = threads () in
  Stdio.printf "baseline threads: %d\n" baseline;
  let failures = ref 0 in
  List.iter [ (`Generation, "raise during GENERATION"); (`Shrink, "raise during SHRINKING") ]
    ~f:(fun (where, name) ->
      let before = threads () in
      let raised = run_and_raise ~where ~domains:4 in
      settle ();
      let after = threads () in
      let leaked = after - before in
      (* Allow a small slack: the runtime may keep a domain or two around
         for its own reasons. A genuine leak of a 4-worker pool shows as
         ~4 per call, and repeated calls would compound. *)
      let ok = raised && leaked <= 1 in
      if not ok then Int.incr failures;
      Stdio.printf "  %-4s %-26s raised=%b threads %d -> %d (delta %+d)\n"
        (if ok then "ok" else "FAIL") name raised before after leaked);
  (* Repeat to catch compounding: a leak that is one pool per call is
     obvious after several. *)
  let before = threads () in
  for _ = 1 to 5 do
    ignore (run_and_raise ~where:`Generation ~domains:4 : bool)
  done;
  settle ();
  let after = threads () in
  let ok = after - before <= 2 in
  if not ok then Int.incr failures;
  Stdio.printf "  %-4s %-26s threads %d -> %d after 5 raising runs (delta %+d)\n"
    (if ok then "ok" else "FAIL") "no compounding leak" before after (after - before);
  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf "%d leak check(s) failed\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "worker domains released on every exception path\n"

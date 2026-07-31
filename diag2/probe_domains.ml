(* The clamp: does asking for more domains than cores get corrected, and
   do results stay identical across domain counts?

   The second half matters more than the first. tapecheck's parallel
   batch evaluation is specified to accept the LOWEST-INDEX improvement,
   i.e. exactly the proposal the sequential scan would have taken, so
   accepted-edit sequences must be identical at every ~domains. If the
   clamp silently changed results, it would be trading a GC problem for
   a correctness one.

   Compare RESULTS only, not attempt counts. The engine documents that a
   pool evaluates each batch speculatively, so "attempt counts (not
   results) may exceed the sequential engine's" -- counts differing
   across domain counts is expected and correct. An earlier version of
   this probe compared counts too and mislabelled that as a difference. *)
open Base
module G = Base_quickcheck.Generator

let run_at domains =
  let found = ref 0 and minimal = ref 0 and calls = ref 0 in
  for t = 0 to 39 do
    match
      Tape_engine.run
        (G.list (G.int_uniform_inclusive 0 1000))
        ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
        ~seed:(t * 1_000_003) ~count:200 ~size:10 ~domains
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; attempts; _ } ->
      Int.incr found;
      calls := !calls + attempts;
      if List.equal Int.equal m [ 100 ] then Int.incr minimal
  done;
  (!found, !minimal, !calls / 40)

let () =
  Stdio.printf "recommended_domain_count = %d\n\n"
    (Stdlib.Domain.recommended_domain_count ());
  let base = run_at 1 in
  List.iter [ 1; 2; 4; 1000 ] ~f:(fun d ->
    let f, m, c = run_at d in
    let bf, bm, bc = base in
    Stdio.printf "  domains %-5d found %2d, minimal %2d, %3d calls  %s\n" d f m c
      (if f = bf && m = bm then "results identical to sequential"
       else "RESULTS DIFFER -- bug");
    ignore (bc : int))

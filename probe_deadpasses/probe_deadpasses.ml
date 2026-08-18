(* Issue #8: are [delete_streams] and the pre-loop trivialization
   attempt dead weight, or an untested capability?

   The report was that stubbing either one out leaves the whole suite
   green, and that stubbing [delete_streams] makes the fn tests CHEAPER
   with identical minimals. "No test fails" is weak evidence on its own
   -- it can equally mean the suite is thin -- so before deleting
   anything this probe tries hard to construct the workload where each
   pass SHOULD pay, and measures whether it does.

   Run it against the stock engine and against a build with the pass
   stubbed, and compare. A difference is the pass earning its keep; no
   difference across workloads chosen to favour it is the case for
   removal.

   W1 and W2 target the trivialization attempt: it sets every choice to
   its target in ONE attempt, so it should win exactly when the trivial
   image already fails, and win biggest when the tape is long.

   W3 and W4 target [delete_streams], which deletes whole non-main
   streams. Streams exist only for Generator.fn (split/perturb), so a
   function generator probed at several arguments is the only shape that
   can possibly benefit -- W4 makes eleven of its twelve arguments
   irrelevant to the failure, which is precisely the case a whole-stream
   deletion is for. *)
open! Base

module G = Base_quickcheck.Generator

let row name ~size_of ~attempts ~converged ~shown =
  Stdio.printf "  %-32s size %-5d attempts %-6d converged %-5b %s\n" name
    size_of attempts converged shown

let list_case name r =
  match r with
  | Tape_engine.Passed _ -> Stdio.printf "  %-32s NO FAILURE FOUND\n" name
  | Tape_engine.Failed { minimal; attempts; converged; _ } ->
    let s = List.map minimal ~f:Int.to_string in
    let s = if List.length s > 8 then List.take s 8 @ [ "..." ] else s in
    row name ~size_of:(List.length minimal) ~attempts ~converged
      ~shown:("[" ^ String.concat ~sep:";" s ^ "]")

(* For fn workloads "size" is the number of probed arguments whose
   result is not already at the shrink target: that is what a successful
   whole-stream deletion would reduce. *)
let fn_case name r =
  match r with
  | Tape_engine.Passed _ -> Stdio.printf "  %-32s NO FAILURE FOUND\n" name
  | Tape_engine.Failed { minimal; attempts; converged; _ } ->
    let vals = List.init 12 ~f:(fun x -> minimal x) in
    let non_target = List.count vals ~f:(fun v -> v <> 0) in
    row name ~size_of:non_target ~attempts ~converged
      ~shown:
        ("["
        ^ String.concat ~sep:";" (List.map vals ~f:Int.to_string)
        ^ "]")

(* W1: ALWAYS fails. This is the trivialization attempt's ideal case and
   is chosen deliberately as such -- the trivial image is a failure by
   construction, the answer is "every choice at target", and one attempt
   reaches it where the per-choice passes must lower forty choices in
   turn. A pass that cannot win here cannot win anywhere.

   Fixed length, so the only work is lowering values. *)
let w1 () =
  Tape_engine.run
    (G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:40)
    ~test:(fun _ -> false)
    ~seed:11 ~count:400 ~size:20

(* W2: the same at 200 elements. The advantage is one attempt against
   O(length) lowerings, so it should grow with the tape. *)
let w2 () =
  Tape_engine.run
    (G.list_with_length (G.int_uniform_inclusive 0 100_000) ~length:200)
    ~test:(fun _ -> false)
    ~seed:12 ~count:400 ~size:30 ~budget:20_000
    ~suppress_health_check:[ Tape_health.Large_base_example ]

(* W2b: less artificial -- fails on any list of three or more, so the
   trivial image still fails but the answer needs deletion as well as
   lowering. Included because W1/W2 are best-case by construction and a
   pass should also be checked on a shape someone might actually write. *)
let w2b () =
  Tape_engine.run
    (G.list (G.int_uniform_inclusive 0 1000))
    ~test:(fun l -> List.length l < 3)
    ~seed:15 ~count:400 ~size:30 ~budget:20_000

(* W3: a generated function probed at twelve arguments, ALL of which
   matter. Streams exist but none is removable -- the control for W4. *)
let w3 () =
  let gen = G.fn Base_quickcheck.Observer.int (G.int_uniform_inclusive 0 1000) in
  Tape_engine.run gen
    ~test:(fun f ->
      List.sum (module Int) (List.init 12 ~f:Fn.id) ~f:(fun x -> f x) < 400)
    ~seed:13 ~count:400 ~size:10 ~budget:8000

(* W4: twelve arguments touched so twelve streams are recorded, but only
   argument 5 decides the verdict. Eleven streams are pure noise. *)
let w4 () =
  let gen = G.fn Base_quickcheck.Observer.int (G.int_uniform_inclusive 0 1000) in
  Tape_engine.run gen
    ~test:(fun f ->
      let touched = List.init 12 ~f:(fun x -> f x) in
      ignore (List.length touched : int);
      f 5 < 200)
    ~seed:14 ~count:400 ~size:10 ~budget:8000

let () =
  Stdio.printf "probe_deadpasses (issue #8)\n\n";
  Stdio.printf "trivialization-favouring (lower size / fewer attempts is better):\n";
  list_case "W1 always-fails, len 40" (w1 ());
  list_case "W2 always-fails, len 200" (w2 ());
  list_case "W2b fails iff len >= 3" (w2b ());
  Stdio.printf "\ndelete_streams-favouring:\n";
  fn_case "W3 fn, all 12 args matter" (w3 ());
  fn_case "W4 fn, only arg 5 matters" (w4 ());
  Stdio.printf "\n"

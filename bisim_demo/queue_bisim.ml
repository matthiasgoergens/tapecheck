(* Worked bisimulation example (task requirement 3): two
   implementations of a FIFO queue, checked against each other.
   [Reference] is obviously correct and slow (append-to-the-end,
   O(n) per enqueue). [Fast] is the standard two-list amortized-O(1)
   queue -- with one deliberately seeded bug: on refilling [front] from
   [back] it forgets to clear [back], so on a LATER refill the same
   elements reappear and get returned a second time. This mirrors what
   Jane Street hand-rolls for real data structures (see
   core/test/test_doubly_linked_bisimulation.ml,
   base_test/test/test_queue.ml): a correct-but-slow version is cheap
   to write, a fast one is easy to get subtly wrong, and bisimulation
   testing is exactly "generate a sequence of operations, run it
   against both, and compare after every step" -- which needs a
   sequence, not just one call, to build up the state where the bug
   actually shows (Yaron Minsky's own framing of Jane Street's internal
   extension, quoted in stateful/bisim.ml's doc comment).

   The bug needs enough enqueue/dequeue interleaving to trigger two
   separate refills-from-back, so the FIRST failing example the engine
   finds is usually a long, noisy sequence; the point of this demo is
   that the tape shrinks it down to (close to) the shortest sequence
   that still triggers exactly that: one refill, re-fill the back
   again without it being cleared, force a second refill. *)

open! Base
open Stdio

module Fast_queue = struct
  type t = { mutable front : int list; mutable back : int list }

  let create () = { front = []; back = [] }

  let enqueue t v = t.back <- v :: t.back

  (* BUG: refilling [front] from [back] should also clear [back]; it
     doesn't, so a second refill later replays [back]'s old contents. *)
  let dequeue t : int option =
    match t.front with
    | x :: rest ->
      t.front <- rest;
      Some x
    | [] -> (
      t.front <- List.rev t.back;
      match t.front with
      | x :: rest ->
        t.front <- rest;
        Some x
      | [] -> None)
end

module Q = struct
  type state = unit
  type left = int list ref (* reference: FIFO via append-at-the-end *)
  type right = Fast_queue.t
  type res = int option

  type cmd =
    | Enqueue of int
    | Dequeue
  [@@deriving sexp_of]

  let init_state = ()
  let init_left () : left = ref []
  let init_right () : right = Fast_queue.create ()
  let cleanup_left (_ : left) = ()
  let cleanup_right (_ : right) = ()

  let arb_cmd (() : state) : cmd Base_quickcheck.Generator.t =
    let module G = Base_quickcheck.Generator in
    G.union
      [ G.map (G.int_uniform_inclusive 0 1000) ~f:(fun v -> Enqueue v)
      ; G.return Dequeue
      ]

  let precond (_ : cmd) (() : state) = true
  let next_state (_ : cmd) (() : state) = ()

  let run_left (cmd : cmd) (left : left) : res =
    match cmd with
    | Enqueue v ->
      left := !left @ [ v ];
      None
    | Dequeue -> (
      match !left with
      | x :: rest ->
        left := rest;
        Some x
      | [] -> None)

  let run_right (cmd : cmd) (right : right) : res =
    match cmd with
    | Enqueue v ->
      Fast_queue.enqueue right v;
      None
    | Dequeue -> Fast_queue.dequeue right

  let equal_res = Option.equal Int.equal
  let sexp_of_res = [%sexp_of: int option]
end

module B = Bisim.Make (Q)

let sexp_of_cmds cmds = [%sexp_of: Q.cmd list] cmds

let () =
  let stats = Bisim.create_stats () in
  let test cmds = B.test ~stats cmds in
  match
    Tape_engine.run (B.gen_cmds ~max_steps:60 ()) ~test ~seed:0 ~count:2000
      ~size:10 ~budget:5000
  with
  | Tape_engine.Passed _ ->
    printf "no divergence found in 2000 cases (bug not seeded correctly?)\n"
  | Tape_engine.Failed { minimal; original; attempts; _ } ->
    printf "original failing sequence: %d ops\n" (List.length original);
    printf "shrunk minimal sequence (%d ops, %d attempts):\n%s\n"
      (List.length minimal) attempts
      (Sexp.to_string_hum (sexp_of_cmds minimal));
    (* Re-run the minimal sequence to show exactly where left/right
       diverge, and print the bisimulation stats/health check. *)
    let stats2 = Bisim.create_stats () in
    (match B.run_cmds ~stats:stats2 minimal with
     | B.Ok_run -> printf "(minimal sequence did not reproduce?!)\n"
     | B.Diverged (idx, cmd, divergence) ->
       printf "diverges at step %d (%s): %s\n" idx
         (Sexp.to_string (Q.sexp_of_cmd cmd))
         (Sexp.to_string (B.sexp_of_divergence divergence)));
    printf "bisim stats over minimal-sequence replay: %s\n"
      (Sexp.to_string_hum (Bisim.sexp_of_stats stats2));
    printf "most_steps_agreed_only_by_raising: %b\n"
      (Bisim.most_steps_agreed_only_by_raising stats2)

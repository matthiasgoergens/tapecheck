(* Shared fixture for the bisimulation worked example AND the tapecheck
   vs. qcheck-stm head-to-head experiment: the SAME buggy fast queue
   implementation must be exercised by both arms of that comparison,
   or the comparison isn't measuring the same bug. Deliberately
   Stdlib-only (no Base) so this compiles unmodified whether it's
   linked against tapecheck's stack or qcheck-stm's.

   The standard two-list amortized-O(1) queue, with one deliberately
   seeded bug: refilling [front] from [back] forgets to clear [back],
   so a LATER refill replays [back]'s old contents a second time. The
   shortest sequence that exposes it is exactly three operations:
   enqueue one value, dequeue it (triggers the first refill), dequeue
   again (empty queue should return [None], but the un-cleared [back]
   causes a second, bogus refill that returns the same value again). *)

type t = { mutable front : int list; mutable back : int list }

let create () = { front = []; back = [] }
let enqueue t v = t.back <- v :: t.back

let dequeue t : int option =
  match t.front with
  | x :: rest ->
    t.front <- rest;
    Some x
  | [] -> (
    t.front <- List.rev t.back;
    (* BUG: should be followed by [t.back <- []]. *)
    match t.front with
    | x :: rest ->
      t.front <- rest;
      Some x
    | [] -> None)

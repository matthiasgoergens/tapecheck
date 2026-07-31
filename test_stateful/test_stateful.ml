(* Acceptance test for Stateful (stateful/stateful.ml): shrinking a
   failing operation sequence must (1) delete operations, (2) shrink
   their arguments, and (3) keep the sequence coherent -- i.e. a
   surviving operation whose argument depends on how many earlier
   operations ran (a Bundle index) must be re-targeted to something
   valid after an earlier operation is deleted, never left dangling.

   The property: a handle allocator. [Alloc v] stores [v] in both a
   real mutable list (the "sut") and a pure model [Bundle]; [Use i]
   reads back entry [i] (newest-first) from the SUT and crashes the
   real system if the stored value is >= 100; [Free i] drops an entry
   from both sides. The unique minimal failing sequence is exactly two
   operations: [Alloc 100; Use 0]. Any additional Alloc/Free/Use noise
   the generator adds before that pair must be deleted, and if noise
   is deleted from BEFORE the fatal Alloc, the fatal Use's bundle index
   must still resolve to the right entry after the tape edit -- if the
   Stateful design were incoherent (e.g. a stale index read out of
   bounds), [List.nth_exn] would raise and CRASH this whole test binary
   rather than merely fail an assertion, so a clean run across many
   seeds is itself the coherence evidence. *)

open! Base
open Stdio

let check name cond = if not cond then failwith ("FAILED: " ^ name)

module HandleAlloc = struct
  type state = { handles : int Stateful.Bundle.t }

  type sut = int list ref

  type cmd =
    | Alloc of int
    | Use of int
    | Free of int
  [@@deriving sexp_of]

  type res = int (* dummy 0 for Alloc/Free; the read-back value for Use *)

  let init_state = { handles = Stateful.Bundle.empty }
  let init_sut () : sut = ref []
  let cleanup (_ : sut) = ()

  let arb_cmd (state : state) : cmd Base_quickcheck.Generator.t =
    let module G = Base_quickcheck.Generator in
    Stateful.rules
      [ (true, G.map (G.int_uniform_inclusive 0 1000) ~f:(fun v -> Alloc v))
      ; ( not (Stateful.Bundle.is_empty state.handles)
        , G.map (Stateful.Bundle.gen_index state.handles) ~f:(fun i -> Use i) )
      ; ( not (Stateful.Bundle.is_empty state.handles)
        , G.map (Stateful.Bundle.gen_index state.handles) ~f:(fun i -> Free i) )
      ]

  let precond (cmd : cmd) (state : state) =
    match cmd with
    | Alloc _ -> true
    | Use i | Free i -> i >= 0 && i < Stateful.Bundle.length state.handles

  let next_state (cmd : cmd) (state : state) : state =
    match cmd with
    | Alloc v -> { handles = Stateful.Bundle.push state.handles v }
    | Use _ -> state
    | Free i -> { handles = Stateful.Bundle.remove state.handles i }

  let run (cmd : cmd) (sut : sut) : res =
    match cmd with
    | Alloc v ->
      sut := v :: !sut;
      0
    | Use i -> List.nth_exn !sut i
    | Free i ->
      sut := List.filteri !sut ~f:(fun j _ -> j <> i);
      0

  (* The bug: reading back a handle whose stored value is >= 100
     crashes the real system. Minimal failing sequence: allocate a
     handle at exactly the boundary, then use it right away. *)
  let postcond (cmd : cmd) (_state : state) (res : res) =
    match cmd with
    | Use _ -> res < 100
    | Alloc _ | Free _ -> true

  (* Always true here -- exercises the invariant hook (Hypothesis's
     @invariant) rather than encoding a real defect. *)
  let invariant (state : state) (sut : sut) =
    Stateful.Bundle.length state.handles = List.length !sut
end

module M = Stateful.Make (HandleAlloc)

let sexp_of_cmds cmds = [%sexp_of: HandleAlloc.cmd list] cmds

let () =
  let trials = 200 in
  let found = ref 0 in
  let minimal_count = ref 0 in
  let max_ops_in_minimal = ref 0 in
  let total_attempts = ref 0 in
  for trial = 0 to trials - 1 do
    let seed = trial * 1_000_003 in
    match
      Tape_engine.run (M.gen_cmds ~max_steps:12 ())
        ~test:M.test ~seed ~count:200 ~size:10 ~budget:5000
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; attempts; original; _ } ->
      Int.incr found;
      total_attempts := !total_attempts + attempts;
      max_ops_in_minimal := max !max_ops_in_minimal (List.length minimal);
      let is_exact_minimal =
        match minimal with
        | [ HandleAlloc.Alloc 100; HandleAlloc.Use 0 ] -> true
        | _ -> false
      in
      if is_exact_minimal then Int.incr minimal_count
      else begin
        printf "non-minimal (seed %d): original had %d ops, shrunk to %s\n"
          seed (List.length original)
          (Sexp.to_string (sexp_of_cmds minimal))
      end
  done;
  printf
    "handle-allocator: found %d/%d, exact minimal [Alloc 100; Use 0] %d/%d, \
     max ops in any minimal %d, avg attempts %d\n"
    !found trials !minimal_count !found !max_ops_in_minimal
    (if !found > 0 then !total_attempts / !found else 0);
  (* The whole point: deletion (fewer ops survive than were generated),
     argument shrinking (the surviving Alloc's value is exactly the
     boundary, not whatever was first generated), and coherence (no
     List.nth_exn crash across 200 seeds, and every reported "minimal"
     re-verified as still-failing by the engine itself before being
     reported, so a dangling/incoherent index could never be shown here
     even once, let alone as THE minimal on nearly every seed). *)
  check "found the bug on every seed" (!found = trials);
  check "reaches the exact 2-op minimal on every seed"
    (!minimal_count = trials);
  printf "stateful shrink-coherence test passed\n"

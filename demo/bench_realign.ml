(* Measurement for the "try both realignment policies" question.

   During shrink replay a proposal can misalign (an edit changes the
   KINDS of later draws, e.g. flipping a tag that selects a differently
   shaped branch). Two policies handle a kind mismatch: Consume (skip
   the stale entry, resync) and Freeze (hold it for a later same-kind
   draw). Neither dominates. `Both replays a misaligned proposal under
   both and keeps the shortlex-better still-failing result.

   This benchmark measures, per policy, the quality of the minimal
   found and the cost paid (generation replays, test executions, and
   how many proposals misaligned at all). Generators are chosen to
   exercise each regime. *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

let seeds = 200

type row =
  { policy : string
  ; found : int
  ; minimal : int (* count that reached the stated ideal *)
  ; size_sum : int (* sum of a size metric over found cases; lower better *)
  ; replays : int
  ; tests : int
  ; misaligns : int
  }

let run_policy (type a) ~name:_ ~gen ~test ~(size_of : a -> int)
    ~(is_minimal : a -> bool) ~realign ~policy_name : row =
  let found = ref 0 in
  let minimal = ref 0 in
  let size_sum = ref 0 in
  let replays = ref 0 in
  let tests = ref 0 in
  let misaligns = ref 0 in
  for s = 0 to seeds - 1 do
    let stats = Tape_engine.no_stats () in
    match
      Tape_engine.run gen ~test ~seed:(s * 2_654_435_761) ~count:300 ~size:12
        ~budget:4000 ~realign ~stats
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; _ } ->
      Int.incr found;
      if is_minimal m then Int.incr minimal;
      size_sum := !size_sum + size_of m;
      replays := !replays + stats.Tape_engine.replays;
      tests := !tests + stats.Tape_engine.tests;
      misaligns := !misaligns + stats.Tape_engine.misaligns
  done;
  { policy = policy_name
  ; found = !found
  ; minimal = !minimal
  ; size_sum = !size_sum
  ; replays = !replays
  ; tests = !tests
  ; misaligns = !misaligns
  }

let bench (type a) ~name ~(gen : a G.t) ~(test : a -> bool)
    ~(size_of : a -> int) ~(is_minimal : a -> bool) =
  printf "%s (%d seeds)\n" name seeds;
  printf
    "  %-8s  found  minimal   avg-size   replays   tests   misaligned\n" "policy";
  List.iter
    [ (`Consume, "consume"); (`Freeze, "freeze"); (`Both, "both") ]
    ~f:(fun (realign, policy_name) ->
      let r =
        run_policy ~name ~gen ~test ~size_of ~is_minimal ~realign ~policy_name
      in
      let per n = if r.found = 0 then 0. else Float.of_int n /. Float.of_int r.found in
      printf "  %-8s  %3d/%d  %3d/%-3d  %9.1f  %8.1f  %6.1f  %6d\n" r.policy
        r.found seeds r.minimal r.found (per r.size_sum) (per r.replays)
        (per r.tests) r.misaligns);
  printf "\n"

let () =
  (* Baseline: no shape change, so replays never misalign; `both must
     cost essentially the same as consume here. *)
  bench ~name:"aligned baseline: list, fail iff sum >= 100"
    ~gen:
      (let open G.Let_syntax in
       let%bind len = G.int_uniform_inclusive 1 32 in
       G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
    ~size_of:(fun l -> List.sum (module Int) l ~f:Fn.id + List.length l)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ]);

  (* Freeze-favouring: flipping the tag from a two-int shape to a
     bool-then-int shape realigns better under Freeze (the first
     recorded int becomes the surviving int), so Consume loses shrink
     progress across the shape change. Ideal: the B shape at the
     boundary, `B (false, 100). *)
  let g_freeze =
    let open G.Let_syntax in
    match%bind G.bool with
    | true ->
      let%map a = G.int_uniform_inclusive 0 1000
      and b = G.int_uniform_inclusive 0 1000 in
      `A (a, b)
    | false ->
      let%map flag = G.bool and c = G.int_uniform_inclusive 0 1000 in
      `B (flag, c)
  in
  bench ~name:"freeze-favouring: tag selects (int,int) vs (bool,int)"
    ~gen:g_freeze
    ~test:(function
      | `A (a, b) -> a + b < 100
      | `B (_, c) -> c < 100)
    ~size_of:(function `A (a, b) -> a + b | `B (f, c) -> c + Bool.to_int f)
    ~is_minimal:(function `B (false, 100) -> true | _ -> false);

  (* Consume-favouring: two bools guard a PAIR of ints whose SUM is
     tested. Flipping the tag from (bool,bool,int,int) to (int,int)
     makes Consume skip the two stale bools and keep BOTH recorded ints
     (carrying the a+b shrink progress), while Freeze fresh-samples both
     and scrambles the sum. Because the values interact, later
     per-choice minimization cannot repair Freeze's loss the way it did
     for a lone int. Ideal: `B (0, 100). *)
  let g_consume =
    let open G.Let_syntax in
    match%bind G.bool with
    | true ->
      let%map _x = G.bool
      and _y = G.bool
      and a = G.int_uniform_inclusive 0 1000
      and b = G.int_uniform_inclusive 0 1000 in
      `A (a, b)
    | false ->
      let%map a = G.int_uniform_inclusive 0 1000
      and b = G.int_uniform_inclusive 0 1000 in
      `B (a, b)
  in
  bench ~name:"consume-favouring: tag selects (bool^2,int,int) vs (int,int)"
    ~gen:g_consume
    ~test:(function `A (a, b) -> a + b < 100 | `B (a, b) -> a + b < 100)
    ~size_of:(function `A (a, b) -> a + b | `B (a, b) -> a + b)
    ~is_minimal:(function `B (0, 100) -> true | _ -> false)

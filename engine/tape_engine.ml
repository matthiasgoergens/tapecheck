(* The runner: generate with a recording tape, and on failure shrink by
   editing the tape and replaying generation through the UNMODIFIED
   base_quickcheck generator. An edit is accepted iff the test still
   fails and the re-recorded output tape is shortlex-smaller.

   Pass schedule ported from the proptest tape engine
   (proptest-rs/proptest#658): one all-choices-to-target attempt, then
   rounds of lower-and-delete (the length-prefix pass) and per-choice
   minimization with bisection, to a fixpoint under an attempt budget. *)

open! Base

type 'a failure =
  { minimal : 'a
  ; original : 'a
  ; attempts : int (* test executions spent shrinking *)
  ; choices : Tape.choice array (* the winning tape, for replay/persistence *)
  }

type 'a result =
  | Passed of { cases : int }
  | Failed of 'a failure

let clamp64 = Tape.clamp_int64

(* Fresh draws during replay (misaligned or overrun positions) sample
   from this fixed seed so every attempt, sequential or pooled, sees
   the same fallback stream. *)
let replay_fresh_seed = 0x7ea9e

let target_of = function
  | Tape.Integer { lo; hi; _ } -> Some (clamp64 0L ~lo ~hi)
  | Tape.Float _ | Tape.Bool _ | Tape.Marker -> None

let choice_at_target = function
  | Tape.Integer { value; lo; hi } -> Int64.(value = clamp64 0L ~lo ~hi)
  | Tape.Float { value; lo; hi } ->
    Float.( = ) value (Float.clamp_exn 0. ~min:lo ~max:hi)
  | Tape.Bool b -> not b
  | Tape.Marker -> true

let trivial_choice = function
  | Tape.Integer { lo; hi; _ } ->
    Tape.Integer { value = clamp64 0L ~lo ~hi; lo; hi }
  | Tape.Float { lo; hi; _ } ->
    Tape.Float { value = Float.clamp_exn 0. ~min:lo ~max:hi; lo; hi }
  | Tape.Bool _ -> Tape.Bool false
  | Tape.Marker -> Tape.Marker

let with_choice tape_choices i c =
  let copy = Array.copy tape_choices in
  copy.(i) <- c;
  copy

let with_deleted_block tape_choices ~pos ~len =
  Array.append
    (Array.sub tape_choices ~pos:0 ~len:pos)
    (Array.sub tape_choices ~pos:(pos + len)
       ~len:(Array.length tape_choices - pos - len))

(* Run one test with the given generator under a tape mode already set
   up by the caller; returns (value, output). *)
let run_case (type a) ~tape ~(gen : a Base_quickcheck.Generator.t) ~size ~seed
    : a * Tape.output =
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
  in
  let value = Base_quickcheck.Generator.generate gen ~size ~random in
  (value, Tape.finish tape)

(* A persistent worker pool: domains are expensive to spawn (each
   registers a GC domain), so spawn once per shrink and feed batches
   through a mutex-protected queue. *)
module Pool = struct
  type 'r t =
    { mutex : Stdlib.Mutex.t
    ; nonempty : Stdlib.Condition.t
    ; all_done : Stdlib.Condition.t
    ; mutable queue : (int * (unit -> 'r)) list
    ; mutable results : ('r, exn) Result.t option array
    ; mutable pending : int
    ; mutable stop : bool
    ; mutable workers : unit Stdlib.Domain.t list
    }

  let rec worker_loop t =
    Stdlib.Mutex.lock t.mutex;
    let rec take () =
      if t.stop then None
      else
        match t.queue with
        | [] ->
          Stdlib.Condition.wait t.nonempty t.mutex;
          take ()
        | (i, task) :: rest ->
          t.queue <- rest;
          Some (i, task)
    in
    match take () with
    | None -> Stdlib.Mutex.unlock t.mutex
    | Some (i, task) ->
      Stdlib.Mutex.unlock t.mutex;
      (* A raising task (user generator or test) must still account for
         itself, or run_batch waits forever; the exception is stored
         and re-raised on the main domain. *)
      let r =
        match task () with
        | r -> Ok r
        | exception exn -> Error exn
      in
      Stdlib.Mutex.lock t.mutex;
      t.results.(i) <- Some r;
      t.pending <- t.pending - 1;
      if t.pending = 0 then Stdlib.Condition.signal t.all_done;
      Stdlib.Mutex.unlock t.mutex;
      worker_loop t

  let create n =
    let t =
      { mutex = Stdlib.Mutex.create ()
      ; nonempty = Stdlib.Condition.create ()
      ; all_done = Stdlib.Condition.create ()
      ; queue = []
      ; results = [||]
      ; pending = 0
      ; stop = false
      ; workers = []
      }
    in
    t.workers <-
      List.init n ~f:(fun _ -> Stdlib.Domain.spawn (fun () -> worker_loop t));
    t

  (* Run tasks to completion; returns results in task order. A task
     that raised has its exception re-raised here, on the caller's
     domain, after the whole batch has been accounted for. *)
  let run_batch t tasks =
    let tasks = Array.of_list tasks in
    let n = Array.length tasks in
    Stdlib.Mutex.lock t.mutex;
    t.results <- Array.create ~len:n None;
    t.pending <- n;
    t.queue <- Array.to_list (Array.mapi tasks ~f:(fun i task -> (i, task)));
    Stdlib.Condition.broadcast t.nonempty;
    while t.pending > 0 do
      Stdlib.Condition.wait t.all_done t.mutex
    done;
    let results = t.results in
    Stdlib.Mutex.unlock t.mutex;
    List.map (List.filter_opt (Array.to_list results)) ~f:(function
      | Ok r -> r
      | Error exn -> raise exn)

  let shutdown t =
    Stdlib.Mutex.lock t.mutex;
    t.stop <- true;
    Stdlib.Condition.broadcast t.nonempty;
    Stdlib.Mutex.unlock t.mutex;
    List.iter t.workers ~f:Stdlib.Domain.join
end

(* Evaluate one proposal in isolation: own tape, own RNG, no shared
   state. Safe to run in a separate domain when the generator and test
   are thread-safe. *)
(* One replay under [policy] on a private tape (own domain safety);
   returns (misaligned, still-failing-candidate). *)
let eval_once (type a) ~(gen : a Base_quickcheck.Generator.t) ~size
    ~(test : a -> bool) ~policy proposal =
  let tape = Tape.create () in
  Tape.start_replay ~policy tape proposal;
  let random =
    Splittable_random.For_tape.attach
      (Splittable_random.of_int replay_fresh_seed)
      tape
  in
  let value = Base_quickcheck.Generator.generate gen ~size ~random in
  let out = Tape.finish tape in
  if out.Tape.overrun then (out.Tape.misaligned, None)
  else if test value then (out.Tape.misaligned, None)
  else (out.Tape.misaligned, Some (out.Tape.choices, value))

(* Pool-side proposal evaluation honouring the realign policy, so a
   pooled run reaches the SAME result as the sequential engine at any
   ?domains (only [`Both] on a misaligned proposal does the second
   replay). *)
let eval_proposal (type a) ~(gen : a Base_quickcheck.Generator.t) ~size
    ~(test : a -> bool) ~(realign : [ `Consume | `Freeze | `Both ]) proposal =
  let primary, secondary =
    match realign with
    | `Freeze -> (Tape.Freeze, Tape.Consume)
    | `Consume | `Both -> (Tape.Consume, Tape.Freeze)
  in
  let mis1, c1 = eval_once ~gen ~size ~test ~policy:primary proposal in
  let cands =
    match realign with
    | `Both when mis1 ->
      let _mis2, c2 = eval_once ~gen ~size ~test ~policy:secondary proposal in
      [ c1; c2 ]
    | _ -> [ c1 ]
  in
  List.filter_opt cands
  |> List.min_elt ~compare:(fun (a, _) (b, _) -> Tape.compare_shortlex a b)

(* Realignment strategy for kind mismatches during shrink replay.
   [`Consume] and [`Freeze] use one fixed policy; [`Both] replays a
   MISALIGNED proposal under both and keeps the shortlex-better still
   -failing result (neither policy dominates, and accepted shrinks
   re-verify through the test, so trying both is sound and >= either
   alone). Aligned proposals never pay the second replay. *)
type realign =
  [ `Consume
  | `Freeze
  | `Both
  ]

(* True cost of a shrink, separate from the proposal-count budget:
   [replays] generation runs, [tests] test executions, [misaligns]
   proposals whose replay hit a kind mismatch (the only ones on which
   [`Both] does extra work). *)
type stats =
  { mutable replays : int
  ; mutable tests : int
  ; mutable misaligns : int
  }

let no_stats () = { replays = 0; tests = 0; misaligns = 0 }

let shrink (type a) ~tape ~(gen : a Base_quickcheck.Generator.t) ~size
    ~(test : a -> bool) ~budget ~domains ~pool ~(realign : realign)
    ~(stats : stats) ~(initial_tape : Tape.choice array)
    ~(initial_value : a) : a * int * Tape.choice array =
  let best_choices = ref initial_tape in
  let best_value = ref initial_value in
  let attempts = ref 0 in

  (* One replay under [policy]; count it, and return a candidate
     (choices, value) iff it is still-failing (could be accepted),
     together with whether the replay misaligned. *)
  let candidate ~policy proposal =
    Tape.start_replay ~policy tape proposal;
    let value, out = run_case ~tape ~gen ~size ~seed:replay_fresh_seed in
    stats.replays <- stats.replays + 1;
    if out.Tape.misaligned then stats.misaligns <- stats.misaligns + 1;
    if out.Tape.overrun then (out.Tape.misaligned, None)
    else begin
      stats.tests <- stats.tests + 1;
      if test value then (out.Tape.misaligned, None)
      else (out.Tape.misaligned, Some (out.Tape.choices, value))
    end
  in

  (* Replay [proposal]; accept iff still failing and shortlex-smaller.
     One logical proposal = one budget tick, regardless of how many
     replays [`Both] spends on it (shrinking is off the CI happy path;
     spend to hand a human a smaller example). *)
  let attempt proposal =
    if !attempts >= budget then false
    else begin
      Int.incr attempts;
      let primary, secondary =
        match realign with
        | `Freeze -> (Tape.Freeze, Tape.Consume)
        | `Consume | `Both -> (Tape.Consume, Tape.Freeze)
      in
      let mis1, c1 = candidate ~policy:primary proposal in
      let cands =
        match realign with
        | `Both when mis1 ->
          let _mis2, c2 = candidate ~policy:secondary proposal in
          [ c1; c2 ]
        | _ -> [ c1 ]
      in
      let best_cand =
        List.filter_opt cands
        |> List.min_elt ~compare:(fun (a, _) (b, _) ->
             Tape.compare_shortlex a b)
      in
      match best_cand with
      | Some (choices, value)
        when Tape.compare_shortlex choices !best_choices < 0 ->
        best_choices := choices;
        best_value := value;
        true
      | _ -> false
    end
  in

  (* Evaluate several independent proposals (in parallel domains when a
     pool exists) and accept the LOWEST-INDEX improvement, exactly the
     proposal the sequential first-accept scan would have taken, so
     accepted-edit sequences are identical at every ?domains. Returns
     the accepted proposal's index, if any. With a pool the whole batch
     is evaluated speculatively, so attempt counts (not results) may
     exceed the sequential engine's. *)
  let attempt_batch proposals =
    let proposals =
      List.take proposals (max 1 (min 64 (budget - !attempts)))
    in
    match (proposals, pool) with
    | [], _ -> None
    | [ p ], _ -> if attempt p then Some 0 else None
    | ps, None ->
      List.foldi ps ~init:None ~f:(fun i acc p ->
        match acc with
        | Some _ -> acc
        | None -> if attempt p then Some i else None)
    | ps, Some pool ->
      let results =
        Pool.run_batch pool
          (List.map ps ~f:(fun p () ->
               eval_proposal ~gen ~size ~test ~realign p))
      in
      attempts := !attempts + List.length ps;
      let accepted =
        List.foldi results ~init:None ~f:(fun i acc r ->
          match (acc, r) with
          | Some _, _ | _, None -> acc
          | None, Some (choices, value) ->
            if Tape.compare_shortlex choices !best_choices < 0 then
              Some (i, choices, value)
            else None)
      in
      (match accepted with
       | Some (i, choices, value) ->
         best_choices := choices;
         best_value := value;
         Some i
       | None -> None)
  in

  (* Pass 1: everything to target at once. *)
  let trivial = Array.map !best_choices ~f:trivial_choice in
  if Tape.compare_shortlex trivial !best_choices < 0 then
    ignore (attempt trivial : bool);

  (* Lower an integer choice by one while deleting one later choice:
     what shrinks length-prefixed data (bind), where neither edit works
     alone. *)
  let lower_and_delete () =
    let improved = ref false in
    let i = ref 0 in
    while !i < Array.length !best_choices && !attempts < budget do
      (match !best_choices.(!i) with
      | Tape.Integer { value; lo; hi }
        when Int64.(value <> clamp64 0L ~lo ~hi) ->
        (* Step one toward the target from EITHER side: length-like
           choices usually sit above it, but nothing guarantees that. *)
        let step =
          if Int64.(value > clamp64 0L ~lo ~hi) then Int64.( - ) value 1L
          else Int64.( + ) value 1L
        in
        let lowered = Tape.Integer { value = step; lo; hi } in
        (* Try deleting a contiguous block of k later choices with the
           lowered prefix; one list element can span several choices
           (e.g. base_quickcheck's list machinery draws a shuffle
           position and a value draw per element), so k ranges over
           small block sizes. Deletable choices cluster early (the
           redistribute pass piles zeros there), so walk j upward, and
           after an accepted deletion stay at the same position: the
           next deletable block usually sits exactly there. *)
        let accepted = ref false in
        let k = ref 1 in
        while (not !accepted) && !k <= 4 && !attempts < budget do
          let j = ref (!i + 1) in
          while
            (not !accepted)
            && !j <= Array.length !best_choices - !k
            && !attempts < budget
          do
            let batch =
              List.filter_map
                (List.init (max 1 (domains * 4)) ~f:(fun d -> !j + d))
                ~f:(fun j ->
                  if j <= Array.length !best_choices - !k then
                    Some
                      (with_deleted_block
                         (with_choice !best_choices !i lowered)
                         ~pos:j ~len:!k)
                  else None)
            in
            (match attempt_batch batch with
            | Some offset ->
              accepted := true;
              improved := true;
              (* Greedily repeat the same edit shape at the position
                 that actually succeeded (the batch may have accepted a
                 later candidate than !j). *)
              let jj = !j + offset in
              let again = ref true in
              while !again && !attempts < budget do
                match !best_choices.(!i) with
                | Tape.Integer { value; lo; hi }
                  when Int64.(value <> clamp64 0L ~lo ~hi)
                       && jj <= Array.length !best_choices - !k ->
                  let step =
                    if Int64.(value > clamp64 0L ~lo ~hi) then
                      Int64.( - ) value 1L
                    else Int64.( + ) value 1L
                  in
                  let lowered = Tape.Integer { value = step; lo; hi } in
                  again :=
                    attempt
                      (with_deleted_block
                         (with_choice !best_choices !i lowered)
                         ~pos:jj ~len:!k)
                | _ -> again := false
              done
            | None -> j := !j + max 1 (domains * 4))
          done;
          Int.incr k
        done;
        if !accepted then i := 0 else Int.incr i
      | _ -> Int.incr i)
    done;
    !improved
  in

  (* Move weight from an earlier integer choice to the next integer
     after it, preserving their sum: [27, 23] becomes [0, 50], after
     which lower-and-delete can drop the zero. This is what turns
     minimal-sum-many-elements local optima into single elements. *)
  let redistribute_pairs () =
    let improved = ref false in
    let i = ref 0 in
    while !i < Array.length !best_choices && !attempts < budget do
      (match !best_choices.(!i) with
      | Tape.Integer { value = vi; lo = lo_i; hi = hi_i }
        when Int64.(vi <> clamp64 0L ~lo:lo_i ~hi:hi_i) -> (
        (* find the next integer choice after i *)
        let j = ref (!i + 1) in
        while
          !j < Array.length !best_choices
          && not (match !best_choices.(!j) with
                  | Tape.Integer _ -> true
                  | _ -> false)
        do
          Int.incr j
        done;
        if !j >= Array.length !best_choices then Int.incr i
        else
          match !best_choices.(!j) with
          | Tape.Integer { value = vj; lo = lo_j; hi = hi_j } ->
            let target_i = clamp64 0L ~lo:lo_i ~hi:hi_i in
            (* Move choice i toward its target and choice j the other
               way, preserving their sum, in whichever direction i
               needs (Hypothesis's redistribute originally handled only
               the above-target side; both sides matter). *)
            let above = Int64.(vi > target_i) in
            let d_max =
              if above then
                Int64.min (Int64.( - ) vi target_i) (Int64.( - ) hi_j vj)
              else Int64.min (Int64.( - ) target_i vi) (Int64.( - ) vj lo_j)
            in
            let d = ref d_max in
            let accepted = ref false in
            while (not !accepted) && Int64.(!d > 0L) && !attempts < budget do
              let new_i =
                if above then Int64.( - ) vi !d else Int64.( + ) vi !d
              in
              let new_j =
                if above then Int64.( + ) vj !d else Int64.( - ) vj !d
              in
              let proposal =
                with_choice
                  (with_choice !best_choices !i
                     (Tape.Integer { value = new_i; lo = lo_i; hi = hi_i }))
                  !j
                  (Tape.Integer { value = new_j; lo = lo_j; hi = hi_j })
              in
              if attempt proposal then begin
                accepted := true;
                improved := true
              end
              else d := Int64.( / ) !d 2L
            done;
            if !accepted then i := 0 else Int.incr i
          | _ -> Int.incr i)
      | _ -> Int.incr i)
    done;
    !improved
  in

  (* Minimize one integer choice toward its target by bisection on
     the DISTANCE from the target, from whichever side the value sits.
     Distances are unsigned int64 (wrapped subtraction is exact modulo
     2^64), so full-range spans like [min_int, max_int] cannot
     overflow. The former exponential probe ladder is gone: it ran
     only under a pool, which made shrink traces depend on ?domains. *)
  let minimize_integer i value lo hi =
    let target = clamp64 0L ~lo ~hi in
    let try_value v =
      attempt (with_choice !best_choices i (Tape.Integer { value = v; lo; hi }))
    in
    if Int64.(value <> target) && not (try_value target) then begin
      let above = Int64.(value > target) in
      let dist =
        if above then Int64.( - ) value target else Int64.( - ) target value
      in
      let of_dist d =
        if above then Int64.( + ) target d else Int64.( - ) target d
      in
      let low = ref 0L and high = ref dist in
      while
        Stdlib.Int64.unsigned_compare (Int64.( - ) !high !low) 1L > 0
        && !attempts < budget
      do
        let mid =
          Int64.( + ) !low
            (Stdlib.Int64.shift_right_logical (Int64.( - ) !high !low) 1)
        in
        if try_value (of_dist mid) then high := mid else low := mid
      done
    end
  in

  let minimize_float i value lo hi =
    let target = Float.clamp_exn 0. ~min:lo ~max:hi in
    let try_value v =
      attempt (with_choice !best_choices i (Tape.Float { value = v; lo; hi }))
    in
    if Float.( <> ) value target && not (try_value target) then begin
      (* Prefer round values, then bisect a bounded number of steps. *)
      let rounded = Float.round_down value in
      if Float.( <> ) rounded value then ignore (try_value rounded : bool);
      let low = ref target and high = ref value in
      let steps = ref 0 in
      while !steps < 40 && !attempts < budget do
        Int.incr steps;
        let mid = !low +. ((!high -. !low) /. 2.) in
        if Float.( = ) mid !low || Float.( = ) mid !high then steps := 40
        else if try_value mid then high := mid
        else low := mid
      done;
      (* One more integer-snap attempt near the found boundary. *)
      let snap = Float.round_up !high in
      if Float.( <> ) snap !high then ignore (try_value snap : bool)
    end
  in

  let minimize_choices () =
    let improved_any = ref false in
    let i = ref 0 in
    while !i < Array.length !best_choices && !attempts < budget do
      let before = !best_choices in
      (match !best_choices.(!i) with
      | Tape.Integer { value; lo; hi } -> minimize_integer !i value lo hi
      | Tape.Float { value; lo; hi } -> minimize_float !i value lo hi
      | Tape.Bool true ->
        ignore (attempt (with_choice !best_choices !i (Tape.Bool false)) : bool)
      | Tape.Bool false | Tape.Marker -> ());
      if not (phys_equal before !best_choices) then improved_any := true;
      Int.incr i
    done;
    !improved_any
  in

  let continue_ = ref true in
  while !continue_ && !attempts < budget do
    let improved = lower_and_delete () in
    let improved = redistribute_pairs () || improved in
    let improved = minimize_choices () || improved in
    continue_ := improved
  done;
  (!best_value, !attempts, !best_choices)

(* Replay a persisted tape: regenerate the value it encodes. Replayed
   values come from the tape itself, so [size] only guides draws past
   the end of a stale tape. *)
let replay (type a) (gen : a Base_quickcheck.Generator.t) ?(size = 30)
    (choices : Tape.choice array) : a =
  let tape = Tape.create () in
  Tape.start_replay tape choices;
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int replay_fresh_seed) tape
  in
  let value = Base_quickcheck.Generator.generate gen ~size ~random in
  let (_ : Tape.output) = Tape.finish tape in
  value

let run (type a) ?(seed = 0) ?(count = 100) ?(size = 10) ?(budget = 2000)
    ?(domains = 1) ?(realign : realign = `Consume) ?stats
    (gen : a Base_quickcheck.Generator.t) ~(test : a -> bool) : a result =
  let stats = match stats with Some s -> s | None -> no_stats () in
  let tape = Tape.create () in
  let pool = if domains > 1 then Some (Pool.create domains) else None in
  (* Find the first failing case. With a pool, generate and test cases
     in parallel batches; taking the lowest failing index in the batch
     preserves the sequential engine's choice of failure exactly. *)
  let first_failure =
    match pool with
    | None ->
      let found = ref None in
      let case = ref 0 in
      while Option.is_none !found && !case < count do
        Tape.start_recording tape;
        let value, out = run_case ~tape ~gen ~size ~seed:(seed + !case) in
        if not (test value) then found := Some (out.Tape.choices, value);
        Int.incr case
      done;
      !found
    | Some pool ->
      let found = ref None in
      let batch_start = ref 0 in
      let width = domains * 2 in
      while Option.is_none !found && !batch_start < count do
        let n = min width (count - !batch_start) in
        let results =
          Pool.run_batch pool
            (List.init n ~f:(fun d () ->
               let tape = Tape.create () in
               Tape.start_recording tape;
               let value, out =
                 run_case ~tape ~gen ~size ~seed:(seed + !batch_start + d)
               in
               if test value then None else Some (out.Tape.choices, value)))
        in
        (* run_batch preserves task order, so the first Some is the
           lowest failing case index. *)
        found := List.find_map results ~f:Fn.id;
        batch_start := !batch_start + n
      done;
      !found
  in
  let outcome =
    match first_failure with
    | None -> Passed { cases = count }
    | Some (choices0, value) ->
      let all_trivial = Array.for_all choices0 ~f:choice_at_target in
      if all_trivial then
        Failed
          { minimal = value; original = value; attempts = 0; choices = choices0 }
      else begin
        let minimal, attempts, choices =
          shrink ~tape ~gen ~size ~test ~budget ~domains ~pool ~realign
            ~stats ~initial_tape:choices0 ~initial_value:value
        in
        Failed { minimal; original = value; attempts; choices }
      end
  in
  Option.iter pool ~f:Pool.shutdown;
  outcome

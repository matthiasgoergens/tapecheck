(* The runner: generate with a recording tape, and on failure shrink by
   editing the tape and replaying generation through the UNMODIFIED
   base_quickcheck generator. An edit is accepted iff the test still
   fails and the re-recorded output tape is shortlex-smaller.

   Pass schedule ported from the proptest tape engine
   (proptest-rs/proptest#658): one all-choices-to-target attempt, then
   rounds of lower-and-delete (the length-prefix pass), whole-stream
   deletion, redistribution, and per-choice minimization with
   bisection, to a fixpoint under an attempt budget.

   Streams (design/stream-keyed-tapes.md): a tape is an image (main
   stream plus keyed sub-streams for split-off PRNG states, i.e.
   generated functions). The test runs BEFORE Tape.finish, because
   function draws happen when the test calls the function; the passes
   iterate every stream, so function behaviour shrinks too. *)

open! Base

type 'a failure =
  { minimal : 'a
  ; original : 'a
  ; attempts : int (* test executions spent shrinking *)
  ; choices : Tape.choice array (* main stream of the winning tape *)
  ; image : Tape.image (* the winning tape, for replay/persistence *)
  }

type 'a result =
  | Passed of { cases : int }
  | Failed of 'a failure

let clamp64 = Tape.clamp_int64

(* Fresh draws during replay (misaligned or overrun positions) sample
   from this fixed seed so every attempt, sequential or pooled, sees
   the same fallback stream. *)
let replay_fresh_seed = 0x7ea9e

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

(* Segments: segment 0 is the main stream, segment s >= 1 is
   streams.(s-1). All shrink passes run over every segment. *)
let seg_count (img : Tape.image) = 1 + Array.length img.streams

let seg_get (img : Tape.image) s =
  if s = 0 then img.main else snd img.streams.(s - 1)

let seg_set (img : Tape.image) s arr : Tape.image =
  if s = 0 then { img with main = arr }
  else
    { img with
      streams =
        Array.mapi img.streams ~f:(fun i (k, a) ->
          if i = s - 1 then (k, arr) else (k, a))
    }

let without_stream (img : Tape.image) s : Tape.image =
  { img with
    streams = Array.filteri img.streams ~f:(fun i _ -> i <> s - 1)
  }

let image_all_trivial (img : Tape.image) =
  Array.for_all img.main ~f:choice_at_target
  && Array.for_all img.streams ~f:(fun (_, arr) ->
       Array.for_all arr ~f:choice_at_target)

let image_trivialized (img : Tape.image) : Tape.image =
  { main = Array.map img.main ~f:trivial_choice
  ; streams =
      Array.map img.streams ~f:(fun (k, arr) ->
        (k, Array.map arr ~f:trivial_choice))
  }

(* Generate under an already-configured tape mode and run the test
   BEFORE finishing the tape: generated functions draw during the test
   call, and those draws belong on the tape. [tested] is [None] when
   the tape had already overrun during generation (the proposal
   truncated; the test is not worth running). *)
let run_and_test (type a) ~tape ~(gen : a Base_quickcheck.Generator.t) ~size
    ~seed ~(test : a -> bool) : a * bool option * Tape.output =
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
  in
  let value = Base_quickcheck.Generator.generate gen ~size ~random in
  let tested =
    if Tape.overrun_now tape then None else Some (test value)
  in
  let out = Tape.finish tape in
  (value, tested, out)

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
   are thread-safe. One replay under [policy]; returns (misaligned,
   still-failing-candidate). *)
let eval_once (type a) ~(gen : a Base_quickcheck.Generator.t) ~size
    ~(test : a -> bool) ~policy proposal =
  let tape = Tape.create () in
  Tape.start_replay_image ~policy tape proposal;
  let _value, tested, out =
    run_and_test ~tape ~gen ~size ~seed:replay_fresh_seed ~test
  in
  match tested with
  | None -> (out.Tape.misaligned, None)
  | Some passed ->
    if out.Tape.overrun || passed then (out.Tape.misaligned, None)
    else
      (out.Tape.misaligned, Some (out.Tape.image, _value))

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
  |> List.min_elt ~compare:(fun (a, _) (b, _) -> Tape.compare_image a b)

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
    ~(stats : stats) ~(initial_tape : Tape.image) ~(initial_value : a) :
    a * int * Tape.image =
  let best = ref initial_tape in
  let best_value = ref initial_value in
  let attempts = ref 0 in

  (* One replay under [policy]; count it, and return a candidate
     (image, value) iff it is still-failing (could be accepted),
     together with whether the replay misaligned. *)
  let candidate ~policy proposal =
    Tape.start_replay_image ~policy tape proposal;
    let value, tested, out =
      run_and_test ~tape ~gen ~size ~seed:replay_fresh_seed ~test
    in
    stats.replays <- stats.replays + 1;
    if out.Tape.misaligned then stats.misaligns <- stats.misaligns + 1;
    match tested with
    | None -> (out.Tape.misaligned, None)
    | Some passed ->
      stats.tests <- stats.tests + 1;
      if out.Tape.overrun || passed then (out.Tape.misaligned, None)
      else (out.Tape.misaligned, Some (out.Tape.image, value))
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
        |> List.min_elt ~compare:(fun (a, _) (b, _) -> Tape.compare_image a b)
      in
      match best_cand with
      | Some (image, value) when Tape.compare_image image !best < 0 ->
        best := image;
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
          | None, Some (image, value) ->
            if Tape.compare_image image !best < 0 then Some (i, image, value)
            else None)
      in
      (match accepted with
       | Some (i, image, value) ->
         best := image;
         best_value := value;
         Some i
       | None -> None)
  in

  (* Pass 1: everything to target at once, across all streams. *)
  let trivial = image_trivialized !best in
  if Tape.compare_image trivial !best < 0 then
    ignore (attempt trivial : bool);

  (* Lower an integer choice by one while deleting one later choice in
     the same stream: what shrinks length-prefixed data (bind), where
     neither edit works alone. *)
  let lower_and_delete () =
    let improved = ref false in
    let s = ref 0 in
    while !s < seg_count !best && !attempts < budget do
      let i = ref 0 in
      while !i < Array.length (seg_get !best !s) && !attempts < budget do
        let arr = seg_get !best !s in
        (match arr.(!i) with
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
              && !j <= Array.length (seg_get !best !s) - !k
              && !attempts < budget
            do
              let arr = seg_get !best !s in
              let batch =
                List.filter_map
                  (List.init (max 1 (domains * 4)) ~f:(fun d -> !j + d))
                  ~f:(fun j ->
                    if j <= Array.length arr - !k then
                      Some
                        (seg_set !best !s
                           (with_deleted_block
                              (with_choice arr !i lowered)
                              ~pos:j ~len:!k))
                    else None)
              in
              (match attempt_batch batch with
              | Some offset ->
                accepted := true;
                improved := true;
                (* Greedily repeat the same edit shape at the position
                   that actually succeeded (the batch may have accepted
                   a later candidate than !j). *)
                let jj = !j + offset in
                let again = ref true in
                while !again && !attempts < budget do
                  let arr = seg_get !best !s in
                  match
                    (if !i < Array.length arr then Some arr.(!i) else None)
                  with
                  | Some (Tape.Integer { value; lo; hi })
                    when Int64.(value <> clamp64 0L ~lo ~hi)
                         && jj <= Array.length arr - !k ->
                    let step =
                      if Int64.(value > clamp64 0L ~lo ~hi) then
                        Int64.( - ) value 1L
                      else Int64.( + ) value 1L
                    in
                    let lowered = Tape.Integer { value = step; lo; hi } in
                    again :=
                      attempt
                        (seg_set !best !s
                           (with_deleted_block
                              (with_choice arr !i lowered)
                              ~pos:jj ~len:!k))
                  | _ -> again := false
                done
              | None -> j := !j + max 1 (domains * 4))
            done;
            Int.incr k
          done;
          if !accepted then i := 0 else Int.incr i
        | _ -> Int.incr i);
        (* An acceptance may change the stream layout; keep s valid. *)
        if !s >= seg_count !best then s := seg_count !best
      done;
      Int.incr s
    done;
    !improved
  in

  (* Delete an entire sub-stream: those draws resample fresh on replay
     (an absent stream is not an overrun), which in practice pushes
     generated functions toward constant observed behaviour. The main
     stream (segment 0) is never deleted. *)
  let delete_streams () =
    let improved = ref false in
    let s = ref 1 in
    while !s < seg_count !best && !attempts < budget do
      if attempt (without_stream !best !s) then improved := true
        (* the array shifted left; stay at the same index *)
      else Int.incr s
    done;
    !improved
  in

  (* Move weight from an earlier integer choice to the next integer
     after it in the same stream, preserving their sum: [27, 23]
     becomes [0, 50], after which lower-and-delete can drop the zero.
     This is what turns minimal-sum-many-elements local optima into
     single elements. *)
  let redistribute_pairs () =
    let improved = ref false in
    let s = ref 0 in
    while !s < seg_count !best && !attempts < budget do
      let i = ref 0 in
      while !i < Array.length (seg_get !best !s) && !attempts < budget do
        let arr = seg_get !best !s in
        (match arr.(!i) with
        | Tape.Integer { value = vi; lo = lo_i; hi = hi_i }
          when Int64.(vi <> clamp64 0L ~lo:lo_i ~hi:hi_i) -> (
          (* find the next integer choice after i *)
          let j = ref (!i + 1) in
          while
            !j < Array.length arr
            && not (match arr.(!j) with
                    | Tape.Integer _ -> true
                    | _ -> false)
          do
            Int.incr j
          done;
          if !j >= Array.length arr then Int.incr i
          else
            match arr.(!j) with
            | Tape.Integer { value = vj; lo = lo_j; hi = hi_j } ->
              let target_i = clamp64 0L ~lo:lo_i ~hi:hi_i in
              (* Move choice i toward its target and choice j the other
                 way, preserving their sum, in whichever direction i
                 needs (Hypothesis's redistribute originally handled
                 only the above-target side; both sides matter). *)
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
                  seg_set !best !s
                    (with_choice
                       (with_choice arr !i
                          (Tape.Integer { value = new_i; lo = lo_i; hi = hi_i }))
                       !j
                       (Tape.Integer { value = new_j; lo = lo_j; hi = hi_j }))
                in
                if attempt proposal then begin
                  accepted := true;
                  improved := true
                end
                else d := Int64.( / ) !d 2L
              done;
              if !accepted then i := 0 else Int.incr i
            | _ -> Int.incr i)
        | _ -> Int.incr i);
        if !s >= seg_count !best then s := seg_count !best
      done;
      Int.incr s
    done;
    !improved
  in

  (* Minimize one integer choice toward its target by bisection on
     the DISTANCE from the target, from whichever side the value sits.
     Distances are unsigned int64 (wrapped subtraction is exact modulo
     2^64), so full-range spans like [min_int, max_int] cannot
     overflow. *)
  let minimize_integer s i value lo hi =
    let target = clamp64 0L ~lo ~hi in
    let try_value v =
      attempt
        (seg_set !best s
           (with_choice (seg_get !best s) i (Tape.Integer { value = v; lo; hi })))
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

  let minimize_float s i value lo hi =
    let target = Float.clamp_exn 0. ~min:lo ~max:hi in
    let try_value v =
      attempt
        (seg_set !best s
           (with_choice (seg_get !best s) i (Tape.Float { value = v; lo; hi })))
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
    let s = ref 0 in
    while !s < seg_count !best && !attempts < budget do
      let i = ref 0 in
      while !i < Array.length (seg_get !best !s) && !attempts < budget do
        let before = !best in
        (match (seg_get !best !s).(!i) with
        | Tape.Integer { value; lo; hi } -> minimize_integer !s !i value lo hi
        | Tape.Float { value; lo; hi } -> minimize_float !s !i value lo hi
        | Tape.Bool true ->
          ignore
            (attempt
               (seg_set !best !s
                  (with_choice (seg_get !best !s) !i (Tape.Bool false)))
              : bool)
        | Tape.Bool false | Tape.Marker -> ());
        if not (phys_equal before !best) then improved_any := true;
        if !s >= seg_count !best then s := seg_count !best else Int.incr i
      done;
      Int.incr s
    done;
    !improved_any
  in

  let continue_ = ref true in
  while !continue_ && !attempts < budget do
    let improved = lower_and_delete () in
    let improved = delete_streams () || improved in
    let improved = redistribute_pairs () || improved in
    let improved = minimize_choices () || improved in
    continue_ := improved
  done;
  (!best_value, !attempts, !best)

(* Replay a persisted tape image and apply [f] to the regenerated
   value. The tape is deliberately left in replay mode: functions
   inside the value keep drawing from the image's streams for as long
   as the value lives (each call rewinds its stream's cursor at the
   perturb boundary, so repeated same-argument calls stay pure), and
   arguments the image never saw sample fresh. *)
let replay_image_and_apply (type a r) (gen : a Base_quickcheck.Generator.t)
    ?(size = 30) (image : Tape.image) ~(f : a -> r) : a * r =
  let tape = Tape.create () in
  Tape.start_replay_image tape image;
  let random =
    Splittable_random.For_tape.attach
      (Splittable_random.of_int replay_fresh_seed)
      tape
  in
  let value = Base_quickcheck.Generator.generate gen ~size ~random in
  let r = f value in
  (value, r)

(* Replay a persisted main-stream tape: regenerate the value it
   encodes. Replayed values come from the tape itself, so [size] only
   guides draws past the end of a stale tape. Note: functions inside
   the value draw fresh once this returns; use [replay_image_and_apply]
   to run a property against the replayed value. *)
let replay (type a) (gen : a Base_quickcheck.Generator.t) ?size
    (choices : Tape.choice array) : a =
  fst
    (replay_image_and_apply gen ?size (Tape.image_of_main choices)
       ~f:(fun _ -> ()))

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
        let value, tested, out =
          run_and_test ~tape ~gen ~size ~seed:(seed + !case) ~test
        in
        (match tested with
         | Some false -> found := Some (out.Tape.image, value)
         | _ -> ());
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
               let value, tested, out =
                 run_and_test ~tape ~gen ~size
                   ~seed:(seed + !batch_start + d) ~test
               in
               match tested with
               | Some false -> Some (out.Tape.image, value)
               | _ -> None))
        in
        (* run_batch preserves task order, so the first Some is the
           lowest failing case index. *)
        found := List.find_map results ~f:Fn.id;
        batch_start := !batch_start + n
      done;
      !found
  in
  (* The reported minimal is regenerated from the winning image on a
     tape left in replay mode, so a counterexample containing functions
     keeps its observed behaviour after the engine returns (a function
     backed by a finished tape would silently fall back to fresh
     randomness on the very calls the report is about). *)
  let live_value image =
    fst (replay_image_and_apply gen ~size image ~f:(fun _ -> ()))
  in
  let outcome =
    match first_failure with
    | None -> Passed { cases = count }
    | Some (image0, value) ->
      if image_all_trivial image0 then
        Failed
          { minimal = live_value image0
          ; original = value
          ; attempts = 0
          ; choices = image0.main
          ; image = image0
          }
      else begin
        let _minimal, attempts, image =
          shrink ~tape ~gen ~size ~test ~budget ~domains ~pool ~realign
            ~stats ~initial_tape:image0 ~initial_value:value
        in
        Failed
          { minimal = live_value image
          ; original = value
          ; attempts
          ; choices = image.main
          ; image
          }
      end
  in
  Option.iter pool ~f:Pool.shutdown;
  outcome

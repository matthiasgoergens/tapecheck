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

let clamp64 v ~lo ~hi = if Int64.(v < lo) then lo else if Int64.(v > hi) then hi else v

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
    Splittable_random.For_tape.attach (Splittable_random.of_int seed)
  in
  Splittable_random.For_tape.set_tape (Some tape);
  let value =
    try Base_quickcheck.Generator.generate gen ~size ~random with
    | e ->
      Splittable_random.For_tape.set_tape None;
      raise e
  in
  Splittable_random.For_tape.set_tape None;
  (value, Tape.finish tape)

let shrink (type a) ~tape ~(gen : a Base_quickcheck.Generator.t) ~size
    ~(test : a -> bool) ~budget ~(initial_tape : Tape.choice array)
    ~(initial_value : a) : a * int * Tape.choice array =
  let best_choices = ref initial_tape in
  let best_value = ref initial_value in
  let attempts = ref 0 in

  (* Replay [proposal]; accept iff still failing and shortlex-smaller. *)
  let attempt proposal =
    if !attempts >= budget then false
    else begin
      Int.incr attempts;
      Tape.start_replay tape proposal;
      let value, out = run_case ~tape ~gen ~size ~seed:0x7ea9e in
      if out.Tape.overrun then false
      else if test value then false
      else if Tape.compare_shortlex out.Tape.choices !best_choices < 0 then begin
        best_choices := out.Tape.choices;
        best_value := value;
        true
      end
      else false
    end
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
      | Tape.Integer { value; lo; hi } when Int64.(value > clamp64 0L ~lo ~hi)
        ->
        let lowered =
          Tape.Integer { value = Int64.(value - 1L); lo; hi }
        in
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
            let proposal =
              with_deleted_block
                (with_choice !best_choices !i lowered)
                ~pos:!j ~len:!k
            in
            if attempt proposal then begin
              accepted := true;
              improved := true;
              (* Greedily repeat the same edit shape in place while it
                 keeps working. *)
              let again = ref true in
              while !again && !attempts < budget do
                match !best_choices.(!i) with
                | Tape.Integer { value; lo; hi }
                  when Int64.(value > clamp64 0L ~lo ~hi)
                       && !j <= Array.length !best_choices - !k ->
                  let lowered =
                    Tape.Integer { value = Int64.(value - 1L); lo; hi }
                  in
                  again :=
                    attempt
                      (with_deleted_block
                         (with_choice !best_choices !i lowered)
                         ~pos:!j ~len:!k)
                | _ -> again := false
              done
            end
            else Int.incr j
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
        when Int64.(vi > clamp64 0L ~lo:lo_i ~hi:hi_i) -> (
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
            let d_max = Int64.min (Int64.( - ) vi target_i) (Int64.( - ) hi_j vj) in
            let d = ref d_max in
            let accepted = ref false in
            while (not !accepted) && Int64.(!d > 0L) && !attempts < budget do
              let proposal =
                with_choice
                  (with_choice !best_choices !i
                     (Tape.Integer
                        { value = Int64.( - ) vi !d; lo = lo_i; hi = hi_i }))
                  !j
                  (Tape.Integer
                     { value = Int64.( + ) vj !d; lo = lo_j; hi = hi_j })
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

  (* Bisect one integer choice toward its target. *)
  let minimize_integer i value lo hi =
    let target = clamp64 0L ~lo ~hi in
    let try_value v =
      attempt (with_choice !best_choices i (Tape.Integer { value = v; lo; hi }))
    in
    if Int64.(value <> target) && not (try_value target) then begin
      (* Invariant: target side fails to reproduce, current side does. *)
      let low = ref target and high = ref value in
      while Int64.(!high - !low > 1L) && !attempts < budget do
        let mid = Int64.(!low + ((!high - !low) / 2L)) in
        if try_value mid then high := mid else low := mid
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

let run (type a) ?(seed = 0) ?(count = 100) ?(size = 10) ?(budget = 2000)
    (gen : a Base_quickcheck.Generator.t) ~(test : a -> bool) : a result =
  let tape = Tape.create () in
  let outcome = ref None in
  let case = ref 0 in
  while Option.is_none !outcome && !case < count do
    Tape.start_recording tape;
    let value, out = run_case ~tape ~gen ~size ~seed:(seed + !case) in
    if not (test value) then begin
      let all_trivial = Array.for_all out.Tape.choices ~f:choice_at_target in
      if all_trivial then
        outcome :=
          Some
            (Failed
               { minimal = value
               ; original = value
               ; attempts = 0
               ; choices = out.Tape.choices
               })
      else begin
        let minimal, attempts, choices =
          shrink ~tape ~gen ~size ~test ~budget
            ~initial_tape:out.Tape.choices ~initial_value:value
        in
        outcome := Some (Failed { minimal; original = value; attempts; choices })
      end
    end;
    Int.incr case
  done;
  match !outcome with
  | Some r -> r
  | None -> Passed { cases = count }

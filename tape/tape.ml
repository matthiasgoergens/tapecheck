(* Choice-tape core, after Hypothesis's Conjecture and our proptest port
   (proptest-rs/proptest#658).

   Generation records every random decision as a typed, bounded choice.
   Shrinking edits the recorded tape and replays generation; an edit is
   accepted iff the test still fails and the re-recorded output tape is
   shortlex-smaller. This module is engine-core only: it knows nothing
   about base_quickcheck. The splittable_random shim calls [draw_*]; the
   engine drives [start_recording] / [start_replay] / [finish]. *)

type choice =
  | Integer of { value : int64; lo : int64; hi : int64 }
  | Float of { value : float; lo : float; hi : float }
  | Bool of bool
  | Marker
      (* Alignment marker for split/perturb: the draws behind it are not
         tape-controlled (generated functions do not shrink). *)

type mode =
  | Off
  | Recording
  | Replaying

(* Realignment policy for kind mismatches during replay. [Consume]
   skips the mismatched input entry and retries at the next position
   (resyncs clean insertions/deletions); [Freeze] leaves the position
   put and fresh-samples just this draw (holds the entry for a later
   same-kind draw). Neither dominates; the engine can try both and keep
   the shortlex-better result. *)
type policy =
  | Consume
  | Freeze

type t = {
  mutable mode : mode;
  (* Output side: choices recorded so far, in reverse. Both recording
     and replaying append here; replay re-records what it actually
     used, so the output tape is always self-consistent. *)
  mutable recorded : choice list;
  (* Input side, replay only. [misaligned] records that at least one
     input choice was skipped over a kind mismatch. *)
  mutable input : choice array;
  mutable pos : int;
  mutable overrun : bool;
  mutable misaligned : bool;
  mutable policy : policy;
}

let create () =
  {
    mode = Off;
    recorded = [];
    input = [||];
    pos = 0;
    overrun = false;
    misaligned = false;
    policy = Consume;
  }

let reset_output t = t.recorded <- []

let start_recording t =
  reset_output t;
  t.mode <- Recording;
  t.input <- [||];
  t.pos <- 0;
  t.overrun <- false;
  t.misaligned <- false

let start_replay ?(policy = Consume) t input =
  reset_output t;
  t.mode <- Replaying;
  t.input <- input;
  t.pos <- 0;
  t.overrun <- false;
  t.misaligned <- false;
  t.policy <- policy

type output = { choices : choice array; overrun : bool; misaligned : bool }

let finish t =
  let choices = Array.of_list (List.rev t.recorded) in
  let overrun = t.overrun in
  let misaligned = t.misaligned in
  t.mode <- Off;
  reset_output t;
  t.input <- [||];
  t.pos <- 0;
  t.overrun <- false;
  t.misaligned <- false;
  { choices; overrun; misaligned }

let record t choice = t.recorded <- choice :: t.recorded

(* Pop the next input choice of the requested kind. On a kind mismatch
   the offending input choice is CONSUMED (skipped) and we retry at the
   next position: freezing the position instead would compare every
   later draw against the same stale entry and silently abandon the
   whole remaining tape after one misalignment. Exhausted input marks
   an overrun so the engine can reject deletion proposals that merely
   truncated. *)
let pop t ~matches =
  match t.mode with
  | Off | Recording -> None
  | Replaying ->
    let take_here () =
      let c = t.input.(t.pos) in
      t.pos <- t.pos + 1;
      c
    in
    let rec consume () =
      if t.pos >= Array.length t.input then (
        t.overrun <- true;
        None)
      else if matches t.input.(t.pos) then Some (take_here ())
      else (
        t.misaligned <- true;
        ignore (take_here ());
        consume ())
    in
    if t.pos >= Array.length t.input then (
      t.overrun <- true;
      None)
    else if matches t.input.(t.pos) then Some (take_here ())
    else (
      t.misaligned <- true;
      match t.policy with
      | Freeze -> None (* leave the position; fresh-sample this draw *)
      | Consume ->
        (* skip the mismatched entry, retry at the next position *)
        ignore (take_here ());
        consume ())

let clamp_int64 v ~lo ~hi = if v < lo then lo else if v > hi then hi else v

let draw_int t ~lo ~hi ~(sample : unit -> int64) : int64 =
  match t.mode with
  | Off -> sample ()
  | Recording | Replaying ->
    let value =
      match pop t ~matches:(function Integer _ -> true | _ -> false) with
      | Some (Integer { value; _ }) -> clamp_int64 value ~lo ~hi
      | _ -> sample ()
    in
    record t (Integer { value; lo; hi });
    value

let clamp_float v ~lo ~hi = if v < lo then lo else if v > hi then hi else v

let draw_float t ~lo ~hi ~(sample : unit -> float) : float =
  match t.mode with
  | Off -> sample ()
  | Recording | Replaying ->
    let value =
      match pop t ~matches:(function Float _ -> true | _ -> false) with
      | Some (Float { value; _ }) ->
        if Float.is_nan value then sample () else clamp_float value ~lo ~hi
      | _ -> sample ()
    in
    record t (Float { value; lo; hi });
    value

let draw_bool t ~(sample : unit -> bool) : bool =
  match t.mode with
  | Off -> sample ()
  | Recording | Replaying ->
    let value =
      match pop t ~matches:(function Bool _ -> true | _ -> false) with
      | Some (Bool b) -> b
      | _ -> sample ()
    in
    record t (Bool value);
    value

let record_marker t =
  match t.mode with
  | Off -> ()
  | Recording | Replaying ->
    (* Consume a matching marker on replay to stay aligned. *)
    ignore (pop t ~matches:(function Marker -> true | _ -> false));
    record t Marker

(* Serialization ("ct1", after the proptest tape engine's format):
   version byte, then one record per choice. Deserialization is total
   over well-formed records via clamping at replay time; a truncated
   or unknown-tag input returns None. *)

let buf_add_int64 buf v =
  for shift = 0 to 7 do
    Buffer.add_char buf
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical v (shift * 8)) 0xffL)))
  done

let serialize (choices : choice array) : string =
  let buf = Buffer.create (Array.length choices * 20) in
  Buffer.add_char buf '\001';
  Array.iter
    (fun c ->
      match c with
      | Integer { value; lo; hi } ->
        Buffer.add_char buf 'i';
        buf_add_int64 buf value;
        buf_add_int64 buf lo;
        buf_add_int64 buf hi
      | Float { value; lo; hi } ->
        Buffer.add_char buf 'f';
        buf_add_int64 buf (Int64.bits_of_float value);
        buf_add_int64 buf (Int64.bits_of_float lo);
        buf_add_int64 buf (Int64.bits_of_float hi)
      | Bool b ->
        Buffer.add_char buf 'b';
        Buffer.add_char buf (if b then '\001' else '\000')
      | Marker -> Buffer.add_char buf 'm')
    choices;
  Buffer.contents buf

let deserialize (s : string) : choice array option =
  let pos = ref 0 in
  let len = String.length s in
  let take_char () =
    if !pos >= len then None
    else begin
      let c = s.[!pos] in
      incr pos;
      Some c
    end
  in
  let take_int64 () =
    if !pos + 8 > len then None
    else begin
      let v = ref 0L in
      for shift = 7 downto 0 do
        v :=
          Int64.logor
            (Int64.shift_left !v 8)
            (Int64.of_int (Char.code s.[!pos + shift]))
      done;
      pos := !pos + 8;
      Some !v
    end
  in
  match take_char () with
  | Some '\001' ->
    let acc = ref [] in
    let ok = ref true in
    while !ok && !pos < len do
      (match take_char () with
       | Some 'i' ->
         (match (take_int64 (), take_int64 (), take_int64 ()) with
          | Some value, Some lo, Some hi ->
            acc := Integer { value; lo; hi } :: !acc
          | _ -> ok := false)
       | Some 'f' ->
         (match (take_int64 (), take_int64 (), take_int64 ()) with
          | Some value, Some lo, Some hi ->
            acc :=
              Float
                { value = Int64.float_of_bits value
                ; lo = Int64.float_of_bits lo
                ; hi = Int64.float_of_bits hi
                }
              :: !acc
          | _ -> ok := false)
       | Some 'b' ->
         (match take_char () with
          | Some '\000' -> acc := Bool false :: !acc
          | Some '\001' -> acc := Bool true :: !acc
          | _ -> ok := false)
       | Some 'm' -> acc := Marker :: !acc
       | _ -> ok := false)
    done;
    if !ok then Some (Array.of_list (List.rev !acc)) else None
  | _ -> None

(* Shortlex order: fewer choices first; ties broken choice-by-choice by
   distance from the shrink target (the value in [lo, hi] closest to
   zero), so "simpler" means shorter, then closer to zero. *)

(* Distance from the shrink target as an UNSIGNED int64 (the wrapped
   subtraction is exact modulo 2^64, so this cannot overflow even for
   full-range spans like [min_int, max_int]), plus which side of the
   target the value sits on. Ordering: smaller distance first; on equal
   distance, above-target before below (the zigzag preference), the
   target itself first of all. *)
let int_distance ~value ~lo ~hi =
  let target = clamp_int64 0L ~lo ~hi in
  if value >= target then (Int64.sub value target, 0) (* above or equal *)
  else (Int64.sub target value, 1) (* below *)

let float_key ~value ~lo ~hi =
  let target = clamp_float 0. ~lo ~hi in
  if Float.is_nan value then Float.infinity else Float.abs (value -. target)

let compare_choice a b =
  match (a, b) with
  | Integer a', Integer b' ->
    let da, sa = int_distance ~value:a'.value ~lo:a'.lo ~hi:a'.hi in
    let db, sb = int_distance ~value:b'.value ~lo:b'.lo ~hi:b'.hi in
    let c = Int64.unsigned_compare da db in
    if c <> 0 then c else compare sa sb
  | Float a', Float b' ->
    compare (float_key ~value:a'.value ~lo:a'.lo ~hi:a'.hi)
      (float_key ~value:b'.value ~lo:b'.lo ~hi:b'.hi)
  | Bool a', Bool b' -> compare a' b'
  | Marker, Marker -> 0
  (* Mixed kinds: stable arbitrary order; mixed comparisons only arise
     on misaligned tapes, which replay re-records anyway. *)
  | Integer _, _ -> -1
  | _, Integer _ -> 1
  | Float _, _ -> -1
  | _, Float _ -> 1
  | Bool _, _ -> -1
  | _, Bool _ -> 1

let compare_shortlex (a : choice array) (b : choice array) =
  let la = Array.length a and lb = Array.length b in
  if la <> lb then compare la lb
  else begin
    let rec go i =
      if i >= la then 0
      else
        let c = compare_choice a.(i) b.(i) in
        if c <> 0 then c else go (i + 1)
    in
    go 0
  end

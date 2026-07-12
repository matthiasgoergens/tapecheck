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

type span = { start : int; stop : int }

type mode =
  | Off
  | Recording
  | Replaying

type t = {
  mutable mode : mode;
  (* Output side: choices recorded so far, in reverse. Both recording
     and replaying append here; replay re-records what it actually
     used, so the output tape is always self-consistent. *)
  mutable recorded : choice list;
  mutable n_recorded : int;
  (* Input side, replay only. *)
  mutable input : choice array;
  mutable pos : int;
  mutable overrun : bool;
  (* Spans: one per generator call boundary, for deletion passes. *)
  mutable spans : span list;
  mutable open_spans : int list;
}

let create () =
  {
    mode = Off;
    recorded = [];
    n_recorded = 0;
    input = [||];
    pos = 0;
    overrun = false;
    spans = [];
    open_spans = [];
  }

let is_on t = t.mode <> Off

let reset_output t =
  t.recorded <- [];
  t.n_recorded <- 0;
  t.spans <- [];
  t.open_spans <- []

let start_recording t =
  reset_output t;
  t.mode <- Recording;
  t.input <- [||];
  t.pos <- 0;
  t.overrun <- false

let start_replay t input =
  reset_output t;
  t.mode <- Replaying;
  t.input <- input;
  t.pos <- 0;
  t.overrun <- false

type output = { choices : choice array; out_spans : span array; overrun : bool }

let finish t =
  let choices = Array.of_list (List.rev t.recorded) in
  let out_spans = Array.of_list (List.rev t.spans) in
  let overrun = t.overrun in
  t.mode <- Off;
  reset_output t;
  t.input <- [||];
  t.pos <- 0;
  t.overrun <- false;
  { choices; out_spans; overrun }

let record t choice =
  t.recorded <- choice :: t.recorded;
  t.n_recorded <- t.n_recorded + 1

let start_span t = t.open_spans <- t.n_recorded :: t.open_spans

let end_span t =
  match t.open_spans with
  | [] -> ()
  | start :: rest ->
    t.open_spans <- rest;
    t.spans <- { start; stop = t.n_recorded } :: t.spans

(* Pop the next input choice if it matches [want]; misaligned or
   exhausted input falls back to fresh sampling (the caller re-records
   whatever it actually used). Exhausted input marks an overrun so the
   engine can reject deletion proposals that merely truncated. *)
let pop t ~matches =
  match t.mode with
  | Off | Recording -> None
  | Replaying ->
    if t.pos >= Array.length t.input then begin
      t.overrun <- true;
      None
    end
    else begin
      let c = t.input.(t.pos) in
      if matches c then begin
        t.pos <- t.pos + 1;
        Some c
      end
      else None
    end

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

(* Shortlex order: fewer choices first; ties broken choice-by-choice by
   distance from the shrink target (the value in [lo, hi] closest to
   zero), so "simpler" means shorter, then closer to zero. *)

let int_key ~value ~lo ~hi =
  let target = clamp_int64 0L ~lo ~hi in
  let d = Int64.sub value target in
  (* zigzag: prefer the target, then small positive, then small negative *)
  if d >= 0L then Int64.mul d 2L else Int64.sub (Int64.mul (Int64.neg d) 2L) 1L

let float_key ~value ~lo ~hi =
  let target = clamp_float 0. ~lo ~hi in
  if Float.is_nan value then Float.infinity else Float.abs (value -. target)

let compare_choice a b =
  match (a, b) with
  | Integer a', Integer b' ->
    compare (int_key ~value:a'.value ~lo:a'.lo ~hi:a'.hi)
      (int_key ~value:b'.value ~lo:b'.lo ~hi:b'.hi)
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

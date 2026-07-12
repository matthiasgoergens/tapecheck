(* Tape shim over Jane Street's splittable_random (vendored as
   Sr_real). Implements the v0.17 public interface; when the engine
   built the state with [For_tape.attach], every draw is recorded as
   (or replayed from) a typed tape choice. States produced by [split]
   are not taped: generated functions draw from a fresh stream and do
   not shrink, matching Hypothesis's limitation. *)

open! Base

type t =
  { real : Sr_real.t
  ; tape : Tape.t option
  }

module For_tape = struct
  (* The tape rides inside the state: no global, so states built for
     different shrink attempts are independent and evaluating attempts
     in parallel domains is data-race-free by construction (each
     attempt has its own Tape.t and its own Sr_real.t). *)
  let attach t tape = { t with tape = Some tape }
end

let active t = t.tape
let create random = { real = Sr_real.create random; tape = None }
let of_int n = { real = Sr_real.of_int n; tape = None }
let copy t = { real = Sr_real.copy t.real; tape = t.tape }

let marker t =
  match active t with
  | Some tape -> Tape.record_marker tape
  | None -> ()

let perturb t salt =
  marker t;
  Sr_real.perturb t.real salt

let split t =
  marker t;
  { real = Sr_real.split t.real; tape = None }

let bool t =
  match active t with
  | None -> Sr_real.bool t.real
  | Some tape -> Tape.draw_bool tape ~sample:(fun () -> Sr_real.bool t.real)

let int t ~lo ~hi =
  match active t with
  | None -> Sr_real.int t.real ~lo ~hi
  | Some tape ->
    Tape.draw_int tape ~lo:(Int64.of_int lo) ~hi:(Int64.of_int hi)
      ~sample:(fun () -> Int64.of_int (Sr_real.int t.real ~lo ~hi))
    |> Int64.to_int_trunc

let int32 t ~lo ~hi =
  match active t with
  | None -> Sr_real.int32 t.real ~lo ~hi
  | Some tape ->
    Tape.draw_int tape ~lo:(Int64.of_int32 lo) ~hi:(Int64.of_int32 hi)
      ~sample:(fun () -> Int64.of_int32 (Sr_real.int32 t.real ~lo ~hi))
    |> Int64.to_int32_trunc

let int63 t ~lo ~hi =
  match active t with
  | None -> Sr_real.int63 t.real ~lo ~hi
  | Some tape ->
    Tape.draw_int tape ~lo:(Int63.to_int64 lo) ~hi:(Int63.to_int64 hi)
      ~sample:(fun () -> Int63.to_int64 (Sr_real.int63 t.real ~lo ~hi))
    |> Int63.of_int64_trunc

let int64 t ~lo ~hi =
  match active t with
  | None -> Sr_real.int64 t.real ~lo ~hi
  | Some tape ->
    Tape.draw_int tape ~lo ~hi ~sample:(fun () -> Sr_real.int64 t.real ~lo ~hi)

let nativeint t ~lo ~hi =
  match active t with
  | None -> Sr_real.nativeint t.real ~lo ~hi
  | Some tape ->
    Tape.draw_int tape
      ~lo:(Stdlib.Int64.of_nativeint lo)
      ~hi:(Stdlib.Int64.of_nativeint hi)
      ~sample:(fun () ->
        Stdlib.Int64.of_nativeint (Sr_real.nativeint t.real ~lo ~hi))
    |> Stdlib.Int64.to_nativeint

let float t ~lo ~hi =
  match active t with
  | None -> Sr_real.float t.real ~lo ~hi
  | Some tape ->
    Tape.draw_float tape ~lo ~hi
      ~sample:(fun () -> Sr_real.float t.real ~lo ~hi)

let unit_float t =
  match active t with
  | None -> Sr_real.unit_float t.real
  | Some tape ->
    Tape.draw_float tape ~lo:0. ~hi:1.
      ~sample:(fun () -> Sr_real.unit_float t.real)

module State = struct
  type nonrec t = t

  let create = create
  let of_int = of_int
  let perturb = perturb
  let copy = copy
  let split = split
end

module Log_uniform = struct
  (* The log-uniform DISTRIBUTION matters only when sampling fresh; the
     recorded constraint is the same [lo, hi], so replay and shrinking
     treat these like any bounded integer draw. *)
  let int t ~lo ~hi =
    match active t with
    | None -> Sr_real.Log_uniform.int t.real ~lo ~hi
    | Some tape ->
      Tape.draw_int tape ~lo:(Int64.of_int lo) ~hi:(Int64.of_int hi)
        ~sample:(fun () ->
          Int64.of_int (Sr_real.Log_uniform.int t.real ~lo ~hi))
      |> Int64.to_int_trunc

  let int32 t ~lo ~hi =
    match active t with
    | None -> Sr_real.Log_uniform.int32 t.real ~lo ~hi
    | Some tape ->
      Tape.draw_int tape ~lo:(Int64.of_int32 lo) ~hi:(Int64.of_int32 hi)
        ~sample:(fun () ->
          Int64.of_int32 (Sr_real.Log_uniform.int32 t.real ~lo ~hi))
      |> Int64.to_int32_trunc

  let int63 t ~lo ~hi =
    match active t with
    | None -> Sr_real.Log_uniform.int63 t.real ~lo ~hi
    | Some tape ->
      Tape.draw_int tape ~lo:(Int63.to_int64 lo) ~hi:(Int63.to_int64 hi)
        ~sample:(fun () ->
          Int63.to_int64 (Sr_real.Log_uniform.int63 t.real ~lo ~hi))
      |> Int63.of_int64_trunc

  let int64 t ~lo ~hi =
    match active t with
    | None -> Sr_real.Log_uniform.int64 t.real ~lo ~hi
    | Some tape ->
      Tape.draw_int tape ~lo ~hi
        ~sample:(fun () -> Sr_real.Log_uniform.int64 t.real ~lo ~hi)

  let nativeint t ~lo ~hi =
    match active t with
    | None -> Sr_real.Log_uniform.nativeint t.real ~lo ~hi
    | Some tape ->
      Tape.draw_int tape
        ~lo:(Stdlib.Int64.of_nativeint lo)
        ~hi:(Stdlib.Int64.of_nativeint hi)
        ~sample:(fun () ->
          Stdlib.Int64.of_nativeint
            (Sr_real.Log_uniform.nativeint t.real ~lo ~hi))
      |> Stdlib.Int64.to_nativeint
end

(* Tape shim over the PATCHED splittable_random (vendored as Sr_real,
   carrying the proposed upstream Intercept seam; see the upstream PR
   branch). The whole interception is now one [Intercept.t] record:
   every bounded integer draw (int, int32, int63, nativeint, and all of
   Log_uniform) reaches the [int64] hook with its bounds, because
   upstream funnels them through [int64]. States produced by [split]
   are hook-free after an [on_split] marker: generated functions draw
   fresh and do not shrink, matching Hypothesis's limitation. *)

open! Base
include Sr_real

module For_tape = struct
  let attach t tape =
    Sr_real.with_intercept t
      { int64 =
          (fun st ~lo ~hi ~default ->
            Tape.draw_int tape ~lo ~hi ~sample:(fun () -> default st ~lo ~hi))
      ; float =
          (fun st ~lo ~hi ~default ->
            Tape.draw_float tape ~lo ~hi
              ~sample:(fun () -> default st ~lo ~hi))
      ; unit_float =
          (fun st ~default ->
            Tape.draw_float tape ~lo:0. ~hi:1. ~sample:(fun () -> default st))
      ; bool =
          (fun st ~default -> Tape.draw_bool tape ~sample:(fun () -> default st))
      ; on_split = (fun () -> Tape.record_marker tape)
      ; on_perturb = (fun () -> Tape.record_marker tape)
      }
end

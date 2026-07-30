(* Performance cost of the explain phase (RO5 half 2, input side): once
   shrinking has converged on a minimal image, how much does
   Tape_explain.analyze add on top? Measured, not assumed, across the
   same property shapes as demo/shrink_table.ml -- a lone scalar, a
   pair, a list, and the bind (length-prefixed list) case where the
   tape model's advantage is sharpest. *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

let seeds = 50

type row =
  { found : int
  ; choices_sum : int (* main-stream length of the minimal tape *)
  ; used_sum : int (* explain replays actually spent *)
  ; complete_count : int (* runs where the budget was NOT exhausted early *)
  ; shrink_attempts_sum : int (* for scale: cost of shrinking itself *)
  ; wall_sum : float (* seconds spent inside analyze, summed *)
  }

let zero_row =
  { found = 0
  ; choices_sum = 0
  ; used_sum = 0
  ; complete_count = 0
  ; shrink_attempts_sum = 0
  ; wall_sum = 0.
  }

let bench (type a) ~name ~(gen : a G.t) ~(test : a -> bool) =
  let acc = ref zero_row in
  for s = 0 to seeds - 1 do
    match
      Tape_engine.run gen ~test ~seed:(s * 1_000_003) ~count:200 ~size:10
        ~budget:2000
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { image; attempts; _ } ->
      let t0 = Stdlib.Sys.time () in
      let report = Tape_explain.analyze ~gen ~size:10 ~test image in
      let elapsed = Stdlib.Sys.time () -. t0 in
      acc :=
        { found = !acc.found + 1
        ; choices_sum = !acc.choices_sum + Array.length image.Tape.main
        ; used_sum = !acc.used_sum + report.used
        ; complete_count = !acc.complete_count + Bool.to_int report.complete
        ; shrink_attempts_sum = !acc.shrink_attempts_sum + attempts
        ; wall_sum = !acc.wall_sum +. elapsed
        }
  done;
  let r = !acc in
  let per n = if r.found = 0 then 0. else Float.of_int n /. Float.of_int r.found in
  let per_f x = if r.found = 0 then 0. else x /. Float.of_int r.found in
  printf "%s (%d seeds, %d found)\n" name seeds r.found;
  printf "  avg minimal-tape choices:   %6.1f\n" (per r.choices_sum);
  printf "  avg shrink attempts:        %6.1f  (cost of shrinking itself)\n"
    (per r.shrink_attempts_sum);
  printf "  avg explain replays used:   %6.1f  (budget %d, default)\n"
    (per r.used_sum) Tape_explain.default_budget;
  printf "  budget exhausted early:     %3d/%d runs\n"
    (r.found - r.complete_count) r.found;
  printf "  avg explain wall time:      %7.5fs\n" (per_f r.wall_sum);
  printf "  total explain wall time:    %7.5fs over %d runs\n\n" r.wall_sum
    r.found

let () =
  bench ~name:"int uniform in [0, 1_000_000], fail iff v >= 123_457"
    ~gen:(G.int_uniform_inclusive 0 1_000_000)
    ~test:(fun v -> v < 123_457);

  bench ~name:"pair in [0,1000]^2, fail iff a + b >= 100"
    ~gen:(G.both (G.int_uniform_inclusive 0 1000) (G.int_uniform_inclusive 0 1000))
    ~test:(fun (a, b) -> a + b < 100);

  bench ~name:"int list, fail iff sum >= 100"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100);

  bench
    ~name:
      "bind: len in [1,64], list_with_length, fail iff sum >= 100 (tape's \
       strongest case)"
    ~gen:
      (let open G.Let_syntax in
       let%bind len = G.int_uniform_inclusive 1 64 in
       G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)

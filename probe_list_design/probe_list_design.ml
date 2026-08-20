(* Wave 2 list-encoding experiment.

   Compare three designs without changing the public generator yet:

   - stock Base_quickcheck: upfront log-uniform length, then shared-budget
     redistribution and permutation;
   - length-int/running-budget: PR #29's essential idea, corrected so only
     optional elements (len - min_length) are charged to the size budget;
   - continuation/running-budget: the same element-size allocation, but the
     existing log-uniform length law encoded as conditional stop decisions.

   The continuation design deliberately preserves Base's marginal length law
   instead of adopting Hypothesis's geometric default. It first records the
   complete continuation prelude, then generates elements. This keeps the
   remaining element budget known while making a shorter length delete a tape
   suffix without increasing any surviving element size. *)
open! Base

module G = Base_quickcheck.Generator

type Splittable_random.span_label += Continuation_element | Recursive_attempt

exception Leaf_limit_reached

type leaf_cap_stats =
  { mutable draws : int
  ; mutable retries : int
  ; mutable max_retries : int
  ; mutable max_leaves_used : int
  }

let leaf_cap_stats =
  { draws = 0; retries = 0; max_retries = 0; max_leaves_used = 0 }
;;

let reset_leaf_cap_stats () =
  leaf_cap_stats.draws <- 0;
  leaf_cap_stats.retries <- 0;
  leaf_cap_stats.max_retries <- 0;
  leaf_cap_stats.max_leaves_used <- 0
;;

(* A direct probe of Hypothesis's [RecursiveStrategy]: wrap the base strategy
   in a shared counter, build a bounded tower of [extend] applications, and
   retry the whole draw when it asks for more than [max_leaves] base values.
   Retries deliberately continue from the advanced random/tape stream, as
   Hypothesis continues drawing from the same ConjectureData. *)
let recursive_with_max_leaves ~base ~extend ~max_leaves =
  if max_leaves <= 0 then invalid_arg "recursive_with_max_leaves: non-positive cap";
  G.create (fun ~size ~random ->
    let remaining = ref max_leaves in
    let limited_base =
      G.create (fun ~size ~random ->
        if !remaining <= 0 then Stdlib.raise_notrace Leaf_limit_reached;
        Int.decr remaining;
        G.generate base ~size ~random)
    in
    let strategies = ref [ limited_base; extend limited_base ] in
    let capacity = ref 2 in
    let keep_growing = ref true in
    while !keep_growing && !capacity <= max_leaves do
      strategies := !strategies @ [ extend (G.union !strategies) ];
      if !capacity > max_leaves / 2
      then keep_growing := false
      else capacity := !capacity * 2
    done;
    let strategy = G.union !strategies in
    let rec attempt retries =
      remaining := max_leaves;
      try
        let value =
          Splittable_random.with_span ~discard_on_exception:true random
            Recursive_attempt ~f:(fun () -> G.generate strategy ~size ~random)
        in
        let leaves_used = max_leaves - !remaining in
        leaf_cap_stats.draws <- leaf_cap_stats.draws + 1;
        leaf_cap_stats.retries <- leaf_cap_stats.retries + retries;
        leaf_cap_stats.max_retries <- Int.max leaf_cap_stats.max_retries retries;
        leaf_cap_stats.max_leaves_used <-
          Int.max leaf_cap_stats.max_leaves_used leaves_used;
        value
      with
      | Leaf_limit_reached -> attempt (retries + 1)
    in
    attempt 0)
;;

let bounded_max_length ~size ~min_length ~requested =
  let upper_bound = min_length + size in
  if upper_bound >= min_length then Int.min requested upper_bound else requested
;;

let bits_to_represent n =
  let rec loop n bits =
    if n = 0 then bits else loop (Int.shift_right n 1) (bits + 1)
  in
  loop n 0
;;

let bit_bucket_size ~lo ~hi value =
  let bits = bits_to_represent value in
  let bucket_lo = if bits = 0 then 0 else Int.shift_left 1 (bits - 1) in
  let bucket_hi = if bits = 0 then 0 else Int.shift_left 1 bits - 1 in
  Int.min hi bucket_hi - Int.max lo bucket_lo + 1
;;

(* [Log_uniform.int] first chooses a bit width uniformly and then a value
   uniformly within that width. The common bit-width factor cancels from the
   conditional probability P(L=k | L>=k), leaving weight 1/bucket_size. *)
let continuation_length_float random ~lo ~hi =
  if lo = hi
  then lo
  else (
    let count = hi - lo + 1 in
    let weights =
      Array.init count ~f:(fun i ->
        1. /. Float.of_int (bit_bucket_size ~lo ~hi (lo + i)))
    in
    let tails = Array.create ~len:count 0. in
    for i = count - 1 downto 0 do
      tails.(i) <- weights.(i) +. if i + 1 < count then tails.(i + 1) else 0.
    done;
    let rec choose i =
      if i = count - 1
      then hi
      else (
        (* Zero is the tape target, so orient the choice as "stop". *)
        let p_stop = weights.(i) /. tails.(i) in
        if Float.( < ) (Splittable_random.unit_float random) p_stop
        then lo + i
        else choose (i + 1))
    in
    choose 0)
;;

(* Approximate the same weighted decision with an integer choice. This is not
   proposed as the final API: it tests whether the poor shrinking of the float
   encoding is caused by representing structural continuation as a Float
   choice rather than a Bool choice. *)
let continuation_length_int random ~lo ~hi =
  if lo = hi
  then lo
  else (
    let count = hi - lo + 1 in
    let weights =
      Array.init count ~f:(fun i ->
        1. /. Float.of_int (bit_bucket_size ~lo ~hi (lo + i)))
    in
    let tails = Array.create ~len:count 0. in
    for i = count - 1 downto 0 do
      tails.(i) <- weights.(i) +. if i + 1 < count then tails.(i + 1) else 0.
    done;
    let scale = 1_000_000 in
    let rec choose i =
      if i = count - 1
      then hi
      else (
        let p_stop = weights.(i) /. tails.(i) in
        let stop_values = Int.max 1 (Float.iround_down_exn (p_stop *. Float.of_int scale)) in
        if Splittable_random.int random ~lo:0 ~hi:(scale - 1) < stop_values
        then lo + i
        else choose (i + 1))
    in
    choose 0)
;;

let continuation_length_bool random ~lo ~hi =
  if lo = hi
  then lo
  else (
    let count = hi - lo + 1 in
    let weights =
      Array.init count ~f:(fun i ->
        1. /. Float.of_int (bit_bucket_size ~lo ~hi (lo + i)))
    in
    let tails = Array.create ~len:count 0. in
    for i = count - 1 downto 0 do
      tails.(i) <- weights.(i) +. if i + 1 < count then tails.(i + 1) else 0.
    done;
    let rec choose i =
      if i = count - 1
      then hi
      else (
        let p_continue = 1. -. (weights.(i) /. tails.(i)) in
        if Splittable_random.bool_with_probability random ~probability:p_continue
        then choose (i + 1)
        else lo + i)
    in
    choose 0)
;;

let generate_elements elt_gen ~size ~min_length ~len ~random =
  (* Match Base's structural charge: only elements beyond [min_length] cost
     one unit. Unlike stock [sizes], leave unused element budget unused; an
     exact sum is incompatible with preserving a prefix when a suffix goes. *)
  let budget = size - (len - min_length) in
  let rec loop i budget acc =
    if i = len
    then List.rev acc
    else (
      let element_size =
        if budget = 0
        then 0
        else Splittable_random.Log_uniform.int random ~lo:0 ~hi:budget
      in
      let value = G.generate elt_gen ~size:element_size ~random in
      loop (i + 1) (budget - element_size) (value :: acc))
  in
  loop 0 budget []
;;

let list_running ?(min_length = 0) ?(max_length = Int.max_value) elt_gen =
  G.create (fun ~size ~random ->
    let hi = bounded_max_length ~size ~min_length ~requested:max_length in
    let len = Splittable_random.Log_uniform.int random ~lo:min_length ~hi in
    generate_elements elt_gen ~size ~min_length ~len ~random)
;;

let list_continuation_with
  continuation_length
  ?(min_length = 0)
  ?(max_length = Int.max_value)
  elt_gen
  =
  G.create (fun ~size ~random ->
    let hi = bounded_max_length ~size ~min_length ~requested:max_length in
    let len = continuation_length random ~lo:min_length ~hi in
    generate_elements elt_gen ~size ~min_length ~len ~random)
;;

let list_continuation_float elt_gen =
  list_continuation_with continuation_length_float elt_gen
;;

let list_continuation_int elt_gen = list_continuation_with continuation_length_int elt_gen
let list_continuation elt_gen = list_continuation_with continuation_length_bool elt_gen

(* Hypothesis-shaped representation: the continuation choice and all draws for
   the element it guards occupy one structural span.  Unlike the earlier
   continuation probe, decisions are interleaved with element generation so a
   complete element can be deleted without leaving an unmatched continuation.

   This arm isolates that structural question: element generation receives the
   ambient size independently of list continuation.  It is deliberately not a
   shippable recursive generator yet; Hypothesis uses a separate [max_leaves]
   mechanism for that safety contract, which is the next design component. *)
let list_continuation_spans elt_gen =
  G.create (fun ~size ~random ->
    let lo = 0 in
    let hi = bounded_max_length ~size ~min_length:lo ~requested:Int.max_value in
    let count = hi - lo + 1 in
    let weights =
      Array.init count ~f:(fun i ->
        1. /. Float.of_int (bit_bucket_size ~lo ~hi (lo + i)))
    in
    let tails = Array.create ~len:count 0. in
    for i = count - 1 downto 0 do
      tails.(i) <- weights.(i) +. if i + 1 < count then tails.(i + 1) else 0.
    done;
    let rec loop length acc =
      let at_maximum = length = hi in
      let p_continue =
        if at_maximum then 0. else 1. -. (weights.(length) /. tails.(length))
      in
      let forced = if at_maximum then Some false else None in
      match
        Splittable_random.with_span ~deletable:true random
          Continuation_element ~f:(fun () ->
          if
            Splittable_random.bool_with_probability random
              ~probability:p_continue ?forced
          then begin
            let value = G.generate elt_gen ~size ~random in
            Some value
          end
          else None)
      with
      | None -> List.rev acc
      | Some value -> loop (length + 1) (value :: acc)
    in
    loop 0 [])

(* The missing cell in the two-axis experiment: keep continuation decisions
   adjacent to their guarded elements, but restore a running size budget.
   Each continued element first pays Base's one-unit structural charge and
   then receives a log-uniform share of what remains.  Exhausting the budget
   forces the next continuation to stop, so the sum of element sizes and
   structural charges cannot exceed the ambient [size]. *)
let list_continuation_spans_budgeted elt_gen =
  G.create (fun ~size ~random ->
    let lo = 0 in
    let hi = bounded_max_length ~size ~min_length:lo ~requested:Int.max_value in
    let count = hi - lo + 1 in
    let weights =
      Array.init count ~f:(fun i ->
        1. /. Float.of_int (bit_bucket_size ~lo ~hi (lo + i)))
    in
    let tails = Array.create ~len:count 0. in
    for i = count - 1 downto 0 do
      tails.(i) <- weights.(i) +. if i + 1 < count then tails.(i + 1) else 0.
    done;
    let rec loop length budget acc =
      let must_stop = length = hi || budget = 0 in
      let p_continue =
        if must_stop then 0. else 1. -. (weights.(length) /. tails.(length))
      in
      let forced = if must_stop then Some false else None in
      match
        Splittable_random.with_span ~deletable:true random
          Continuation_element ~f:(fun () ->
          if
            Splittable_random.bool_with_probability random
              ~probability:p_continue ?forced
          then begin
            let budget = budget - 1 in
            let element_size =
              if budget = 0
              then 0
              else Splittable_random.Log_uniform.int random ~lo:0 ~hi:budget
            in
            let value = G.generate elt_gen ~size:element_size ~random in
            Some (value, budget - element_size)
          end
          else None)
      with
      | None -> List.rev acc
      | Some (value, budget) -> loop (length + 1) budget (value :: acc)
    in
    loop 0 size [])

(* Keep structural continuation independent of the running budget, and spend
   that budget only on element payload sizes.  This preserves the continuation
   length law even after an early element consumes all remaining payload
   budget.  The resulting contract deliberately counts list nodes separately:
   both length and aggregate element size are bounded by [size], rather than
   their sum being bounded by [size]. *)
let list_continuation_spans_payload_budgeted elt_gen =
  G.create (fun ~size ~random ->
    let lo = 0 in
    let hi = bounded_max_length ~size ~min_length:lo ~requested:Int.max_value in
    let count = hi - lo + 1 in
    let weights =
      Array.init count ~f:(fun i ->
        1. /. Float.of_int (bit_bucket_size ~lo ~hi (lo + i)))
    in
    let tails = Array.create ~len:count 0. in
    for i = count - 1 downto 0 do
      tails.(i) <- weights.(i) +. if i + 1 < count then tails.(i + 1) else 0.
    done;
    let rec loop length budget acc =
      let at_maximum = length = hi in
      let p_continue =
        if at_maximum then 0. else 1. -. (weights.(length) /. tails.(length))
      in
      let forced = if at_maximum then Some false else None in
      match
        Splittable_random.with_span ~deletable:true random
          Continuation_element ~f:(fun () ->
          if
            Splittable_random.bool_with_probability random
              ~probability:p_continue ?forced
          then begin
            let element_size =
              if budget = 0
              then 0
              else Splittable_random.Log_uniform.int random ~lo:0 ~hi:budget
            in
            let value = G.generate elt_gen ~size:element_size ~random in
            Some (value, budget - element_size)
          end
          else None)
      with
      | None -> List.rev acc
      | Some (value, budget) -> loop (length + 1) budget (value :: acc)
    in
    loop 0 size [])

let count_choices image =
  Array.length image.Tape.main
  + Array.fold image.Tape.streams ~init:0 ~f:(fun n (_, xs) -> n + Array.length xs)
;;

let quality ~name ~gen ~test ~is_minimal ~show =
  let found = ref 0 in
  let minimal = ref 0 in
  let attempts = ref 0 in
  let stuck = ref [] in
  for seed = 0 to 99 do
    match
      Tape_engine.run gen ~test ~seed:(seed * 1_000_003) ~count:200 ~size:10
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = value; attempts = n; _ } ->
      Int.incr found;
      attempts := !attempts + n;
      if is_minimal value
      then Int.incr minimal
      else if List.length !stuck < 5 then stuck := show value :: !stuck
  done;
  Stdio.printf
    "    %-16s found %3d, minimal %3d, %4s shrink attempts/failure\n"
    name
    !found
    !minimal
    (if !found = 0 then "n/a" else Int.to_string (!attempts / !found))
  ;
  if not (List.is_empty !stuck) then
    Stdio.printf "      first non-minima: %s\n" (String.concat ~sep:"; " (List.rev !stuck))
;;

let distribution ~name ~gen ~size ~samples =
  let counts = Array.create ~len:(size + 1) 0 in
  let choices = ref 0 in
  let elements = ref 0 in
  for seed = 0 to samples - 1 do
    match
      Tape_engine.run gen ~test:(fun _ -> false) ~seed ~count:1 ~size ~budget:0
    with
    | Tape_engine.Passed _ -> assert false
    | Tape_engine.Failed { original; image; _ } ->
      counts.(List.length original) <- counts.(List.length original) + 1;
      choices := !choices + count_choices image;
      elements := !elements + List.length original
  done;
  let mean =
    Array.foldi counts ~init:0. ~f:(fun i total count ->
      total +. (Float.of_int (i * count) /. Float.of_int samples))
  in
  Stdio.printf
    "  %-16s mean length %.3f, choices %.2f, choices/element %.2f\n"
    name
    mean
    (Float.of_int !choices /. Float.of_int samples)
    (Float.of_int !choices /. Float.of_int (Int.max 1 !elements));
  counts
;;

let raw_distribution ~name ~gen ~size ~samples =
  let counts = Array.create ~len:(size + 1) 0 in
  for seed = 0 to samples - 1 do
    let value = G.generate gen ~size ~random:(Splittable_random.of_int seed) in
    counts.(List.length value) <- counts.(List.length value) + 1
  done;
  let mean =
    Array.foldi counts ~init:0. ~f:(fun i total count ->
      total +. (Float.of_int (i * count) /. Float.of_int samples))
  in
  Stdio.printf "  %-16s mean length %.3f\n" name mean;
  counts
;;

let chi_square a b =
  let total_a = Float.of_int (Array.sum (module Int) a ~f:Fn.id) in
  let total_b = Float.of_int (Array.sum (module Int) b ~f:Fn.id) in
  Array.foldi a ~init:0. ~f:(fun i result observed_a ->
    let observed_b = b.(i) in
    let pooled = Float.of_int (observed_a + observed_b) in
    if Float.equal pooled 0.
    then result
    else (
      let expected_a = pooled *. total_a /. (total_a +. total_b) in
      let expected_b = pooled -. expected_a in
      result
      +. ((Float.of_int observed_a -. expected_a) **. 2. /. expected_a)
      +. ((Float.of_int observed_b -. expected_b) **. 2. /. expected_b)))
;;

type tree =
  | Leaf
  | Node of tree list

let rec tree_nodes = function
  | Leaf -> 1
  | Node children -> 1 + List.sum (module Int) children ~f:tree_nodes
;;

let rec tree_leaves = function
  | Leaf -> 1
  | Node children -> List.sum (module Int) children ~f:tree_leaves
;;

let tree list = G.recursive_union [ G.return Leaf ] ~f:(fun self -> [ G.map (list self) ~f:(fun xs -> Node xs) ])

let leaf_capped_tree list ~max_leaves =
  recursive_with_max_leaves
    ~base:(G.return Leaf)
    ~extend:(fun self -> G.map (list self) ~f:(fun xs -> Node xs))
    ~max_leaves
;;

let generation_tail ~name ~gen ~size ~samples ~measure =
  let total = ref 0 in
  let maximum = ref 0 in
  for seed = 0 to samples - 1 do
    let value = G.generate gen ~size ~random:(Splittable_random.of_int seed) in
    let n = measure value in
    total := !total + n;
    maximum := Int.max !maximum n
  done;
  Stdio.printf
    "  %-16s mean %.2f, max %d (%d samples, size %d)\n"
    name
    (Float.of_int !total /. Float.of_int samples)
    !maximum
    samples
    size
;;

let taped_generation_tail ~name ~gen ~size ~samples ~measure =
  let total_measure = ref 0 in
  let max_measure = ref 0 in
  let total_choices = ref 0 in
  let max_choices = ref 0 in
  let total_discarded_choices = ref 0 in
  for seed = 0 to samples - 1 do
    (* Record exactly one fresh generation.  Going through [Tape_engine.run]
       would add its eight determinism replays and final live-value replay,
       contaminating a measurement of generation-time retry behaviour. *)
    let tape = Tape.create () in
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
    in
    let value = G.generate gen ~size ~random in
    let out = Tape.finish tape in
    let measured = measure value in
    let choices = count_choices out.image in
    let discarded_choices =
      (* Recursive-attempt spans in this probe are sequential, never nested,
         so summing their lengths counts each abandoned choice exactly once. *)
      Array.sum
        (module Int)
        out.spans
        ~f:(fun (span : Tape.span) ->
          if span.discarded then span.stop - span.start else 0)
    in
    total_measure := !total_measure + measured;
    max_measure := Int.max !max_measure measured;
    total_choices := !total_choices + choices;
    max_choices := Int.max !max_choices choices;
    total_discarded_choices := !total_discarded_choices + discarded_choices
  done;
  Stdio.printf
    "  %-16s mean value %.2f, max %d; mean choices %.2f, max %d; discarded %.2f (%d samples)\n"
    name
    (Float.of_int !total_measure /. Float.of_int samples)
    !max_measure
    (Float.of_int !total_choices /. Float.of_int samples)
    !max_choices
    (Float.of_int !total_discarded_choices /. Float.of_int samples)
    samples
;;

let tree_quality ~name ~gen ~threshold =
  let found = ref 0 in
  let exact = ref 0 in
  let attempts = ref 0 in
  let choices = ref 0 in
  let discarded_attempts = ref 0 in
  let worst = ref 0 in
  for seed = 0 to 49 do
    match
      Tape_engine.run gen ~seed:(seed * 1_000_003) ~count:200 ~size:50
        ~budget:5_000 ~test:(fun tree -> tree_nodes tree < threshold)
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; attempts = n; image; _ } ->
      let nodes = tree_nodes minimal in
      Int.incr found;
      attempts := !attempts + n;
      choices := !choices + count_choices image;
      discarded_attempts :=
        !discarded_attempts
        + List.Assoc.find_exn (Tape_engine.Diagnostics.last_pass_costs ())
            ~equal:String.equal "remove_discarded";
      worst := Int.max !worst nodes;
      if nodes = threshold then Int.incr exact
  done;
  Stdio.printf
    "  %-16s found %2d, exact %2d, worst %d, %s attempts, %s choices/failure, %d discarded-pass total\n"
    name
    !found
    !exact
    !worst
    (if !found = 0 then "n/a" else Int.to_string (!attempts / !found))
    (if !found = 0 then "n/a" else Int.to_string (!choices / !found))
    !discarded_attempts
;;

let () =
  let show_ints xs =
    "[" ^ String.concat ~sep:"; " (List.map xs ~f:Int.to_string) ^ "]"
  in
  let show_strings xs =
    "["
    ^ String.concat ~sep:"; " (List.map xs ~f:(Printf.sprintf "%S"))
    ^ "]"
  in
  let int100 = G.int_uniform_inclusive 0 100 in
  let int1000 = G.int_uniform_inclusive 0 1000 in
  let stock elt = G.list elt in
  let running elt = list_running elt in
  let continuation elt = list_continuation elt in
  let continuation_spans elt = list_continuation_spans elt in
  let continuation_spans_budgeted elt = list_continuation_spans_budgeted elt in
  let continuation_spans_payload_budgeted elt =
    list_continuation_spans_payload_budgeted elt
  in

  Stdio.printf "RAW LENGTH DISTRIBUTION (size 10, 20k samples)\n";
  let raw_stock = raw_distribution ~name:"stock" ~gen:(stock int100) ~size:10 ~samples:20_000 in
  let raw_continuation =
    raw_distribution ~name:"continuation" ~gen:(continuation int100) ~size:10 ~samples:20_000
  in
  ignore
    (raw_distribution ~name:"continuation+span"
       ~gen:(continuation_spans int100) ~size:10 ~samples:20_000
     : int array);
  ignore
    (raw_distribution ~name:"cont+span+bud"
       ~gen:(continuation_spans_budgeted int100) ~size:10 ~samples:20_000
     : int array);
  ignore
    (raw_distribution ~name:"span+payload-bud"
       ~gen:(continuation_spans_payload_budgeted int100) ~size:10 ~samples:20_000
     : int array);
  Stdio.printf
    "  stock vs continuation two-sample chi-square %.2f (%d bins)\n"
    (chi_square raw_stock raw_continuation)
    (Array.length raw_stock);

  Stdio.printf "\nTAPED LENGTH DISTRIBUTION AND COST (size 10, 20k samples)\n";
  let stock_counts = distribution ~name:"stock" ~gen:(stock int100) ~size:10 ~samples:20_000 in
  ignore (distribution ~name:"length-int" ~gen:(running int100) ~size:10 ~samples:20_000 : int array);
  let continuation_counts =
    distribution ~name:"continuation" ~gen:(continuation int100) ~size:10 ~samples:20_000
  in
  ignore
    (distribution ~name:"continuation+span"
       ~gen:(continuation_spans int100) ~size:10 ~samples:20_000
     : int array);
  ignore
    (distribution ~name:"cont+span+bud"
       ~gen:(continuation_spans_budgeted int100) ~size:10 ~samples:20_000
     : int array);
  ignore
    (distribution ~name:"span+payload-bud"
       ~gen:(continuation_spans_payload_budgeted int100) ~size:10 ~samples:20_000
     : int array);
  Stdio.printf
    "  stock vs continuation two-sample chi-square %.2f (%d bins)\n"
    (chi_square stock_counts continuation_counts)
    (Array.length stock_counts);

  ignore
    (distribution
       ~name:"continuation-f"
       ~gen:(list_continuation_float int100)
       ~size:10
       ~samples:20_000
     : int array);
  ignore
    (distribution
       ~name:"continuation-i"
       ~gen:(list_continuation_int int100)
       ~size:10
       ~samples:20_000
     : int array);

  Stdio.printf "\nSHRINK QUALITY (100 seeds)\n";
  let run_case : type a.
    string ->
    a G.t ->
    show:(a list -> string) ->
    test:(a list -> bool) ->
    minimal:(a list -> bool) ->
    unit =
    fun label elt ~show ~test ~minimal ->
    Stdio.printf "  %s\n" label;
    quality ~name:"stock" ~gen:(stock elt) ~test ~is_minimal:minimal ~show;
    quality ~name:"length-int" ~gen:(running elt) ~test ~is_minimal:minimal ~show;
    quality ~name:"continuation" ~gen:(continuation elt) ~test ~is_minimal:minimal ~show;
    quality ~name:"continuation+span" ~gen:(continuation_spans elt) ~test
      ~is_minimal:minimal ~show;
    quality ~name:"cont+span+bud" ~gen:(continuation_spans_budgeted elt) ~test
      ~is_minimal:minimal ~show;
    quality ~name:"span+payload-bud"
      ~gen:(continuation_spans_payload_budgeted elt) ~test ~is_minimal:minimal
      ~show
  in
  run_case
    "length >= 3 (minimum [0;0;0])"
    int100
    ~show:show_ints
    ~test:(fun xs -> List.length xs < 3)
    ~minimal:(List.equal Int.equal [ 0; 0; 0 ]);
  run_case
    "sum >= 100 (minimum [100])"
    int1000
    ~show:show_ints
    ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
    ~minimal:(List.equal Int.equal [ 100 ]);
  run_case
    "hd = length (minimum [1])"
    (G.int_uniform_inclusive 0 50)
    ~show:show_ints
    ~test:(fun xs ->
      match xs with
      | [] -> true
      | x :: _ -> x <> List.length xs)
    ~minimal:(List.equal Int.equal [ 1 ]);
  run_case
    "ten strings (minimum ten empty strings)"
    G.string
    ~show:show_strings
    ~test:(fun xs -> List.length xs < 10)
    ~minimal:(fun xs -> List.length xs = 10 && List.for_all xs ~f:String.is_empty);

  Stdio.printf "\nRECURSIVE SHRINK QUALITY (50 seeds, fail at 20 nodes)\n";
  tree_quality ~name:"stock tree" ~gen:(tree stock) ~threshold:20;
  let capped_tree = leaf_capped_tree continuation_spans ~max_leaves:100 in
  tree_quality ~name:"cont+span capped" ~gen:capped_tree ~threshold:20;
  let budgeted_capped_tree =
    leaf_capped_tree continuation_spans_budgeted ~max_leaves:100
  in
  tree_quality ~name:"span+bud capped" ~gen:budgeted_capped_tree ~threshold:20;
  let payload_budgeted_capped_tree =
    leaf_capped_tree continuation_spans_payload_budgeted ~max_leaves:100
  in
  tree_quality ~name:"payload-bud cap" ~gen:payload_budgeted_capped_tree
    ~threshold:20;

  Stdio.printf "\nGENERATION TAILS\n";
  generation_tail ~name:"stock strings" ~gen:(stock G.string) ~size:50 ~samples:10_000
    ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"running strings" ~gen:(running G.string) ~size:50 ~samples:10_000
    ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"continuation str" ~gen:(continuation G.string) ~size:50 ~samples:10_000
    ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"cont+span str" ~gen:(continuation_spans G.string) ~size:50
    ~samples:10_000 ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"span+bud str" ~gen:(continuation_spans_budgeted G.string)
    ~size:50 ~samples:10_000 ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"payload-bud str"
    ~gen:(continuation_spans_payload_budgeted G.string) ~size:50 ~samples:10_000
    ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"stock tree" ~gen:(tree stock) ~size:50 ~samples:10_000
    ~measure:tree_nodes;
  generation_tail ~name:"running tree" ~gen:(tree running) ~size:50 ~samples:10_000
    ~measure:tree_nodes;
  generation_tail ~name:"continuation tree" ~gen:(tree continuation) ~size:50 ~samples:10_000
    ~measure:tree_nodes;
  reset_leaf_cap_stats ();
  generation_tail ~name:"cont+span capped" ~gen:capped_tree ~size:50 ~samples:10_000
    ~measure:tree_nodes;
  generation_tail ~name:"  capped leaves" ~gen:capped_tree ~size:50 ~samples:10_000
    ~measure:tree_leaves;
  Stdio.printf
    "  leaf-cap retries  %d over %d successful draws, max %d; max leaves charged %d\n"
    leaf_cap_stats.retries
    leaf_cap_stats.draws
    leaf_cap_stats.max_retries
    leaf_cap_stats.max_leaves_used;
  reset_leaf_cap_stats ();
  generation_tail ~name:"span+bud capped" ~gen:budgeted_capped_tree ~size:50
    ~samples:10_000 ~measure:tree_nodes;
  generation_tail ~name:"  budgeted leaves" ~gen:budgeted_capped_tree ~size:50
    ~samples:10_000 ~measure:tree_leaves;
  Stdio.printf
    "  budgeted retries %d over %d successful draws, max %d; max leaves charged %d\n"
    leaf_cap_stats.retries
    leaf_cap_stats.draws
    leaf_cap_stats.max_retries
    leaf_cap_stats.max_leaves_used;
  reset_leaf_cap_stats ();
  generation_tail ~name:"payload-bud cap" ~gen:payload_budgeted_capped_tree
    ~size:50 ~samples:10_000 ~measure:tree_nodes;
  generation_tail ~name:"  payload leaves" ~gen:payload_budgeted_capped_tree
    ~size:50 ~samples:10_000 ~measure:tree_leaves;
  Stdio.printf
    "  payload retries  %d over %d successful draws, max %d; max leaves charged %d\n"
    leaf_cap_stats.retries
    leaf_cap_stats.draws
    leaf_cap_stats.max_retries
    leaf_cap_stats.max_leaves_used;
  Stdio.printf "\nTAPED RECURSIVE COSTS\n";
  taped_generation_tail ~name:"stock tree" ~gen:(tree stock) ~size:50 ~samples:1_000
    ~measure:tree_nodes;
  reset_leaf_cap_stats ();
  taped_generation_tail ~name:"cont+span capped" ~gen:capped_tree ~size:50 ~samples:1_000
    ~measure:tree_nodes;
  Stdio.printf
    "  taped cap retries %d over %d successful draws, max %d\n"
    leaf_cap_stats.retries
    leaf_cap_stats.draws
    leaf_cap_stats.max_retries;
  reset_leaf_cap_stats ();
  taped_generation_tail ~name:"span+bud capped" ~gen:budgeted_capped_tree ~size:50
    ~samples:1_000 ~measure:tree_nodes;
  Stdio.printf
    "  taped bud retries %d over %d successful draws, max %d\n"
    leaf_cap_stats.retries
    leaf_cap_stats.draws
    leaf_cap_stats.max_retries;
  reset_leaf_cap_stats ();
  taped_generation_tail ~name:"payload-bud cap" ~gen:payload_budgeted_capped_tree
    ~size:50 ~samples:1_000 ~measure:tree_nodes;
  Stdio.printf
    "  taped payload retries %d over %d successful draws, max %d\n"
    leaf_cap_stats.retries
    leaf_cap_stats.draws
    leaf_cap_stats.max_retries
;;

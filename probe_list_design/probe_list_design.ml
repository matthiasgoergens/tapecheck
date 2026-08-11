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

let count_choices image =
  Array.length image.Tape.main
  + Array.fold image.Tape.streams ~init:0 ~f:(fun n (_, xs) -> n + Array.length xs)
;;

let quality ~name ~gen ~test ~is_minimal =
  let found = ref 0 in
  let minimal = ref 0 in
  let attempts = ref 0 in
  for seed = 0 to 99 do
    match
      Tape_engine.run gen ~test ~seed:(seed * 1_000_003) ~count:200 ~size:10
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = value; attempts = n; _ } ->
      Int.incr found;
      attempts := !attempts + n;
      if is_minimal value then Int.incr minimal
  done;
  Stdio.printf
    "    %-16s found %3d, minimal %3d, %4s shrink attempts/failure\n"
    name
    !found
    !minimal
    (if !found = 0 then "n/a" else Int.to_string (!attempts / !found))
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

let tree list = G.recursive_union [ G.return Leaf ] ~f:(fun self -> [ G.map (list self) ~f:(fun xs -> Node xs) ])

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

let () =
  let int100 = G.int_uniform_inclusive 0 100 in
  let int1000 = G.int_uniform_inclusive 0 1000 in
  let stock elt = G.list elt in
  let running elt = list_running elt in
  let continuation elt = list_continuation elt in

  Stdio.printf "RAW LENGTH DISTRIBUTION (size 10, 20k samples)\n";
  let raw_stock = raw_distribution ~name:"stock" ~gen:(stock int100) ~size:10 ~samples:20_000 in
  let raw_continuation =
    raw_distribution ~name:"continuation" ~gen:(continuation int100) ~size:10 ~samples:20_000
  in
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
  let run_case : type a. string -> a G.t -> test:(a list -> bool) -> minimal:(a list -> bool) -> unit =
    fun label elt ~test ~minimal ->
    Stdio.printf "  %s\n" label;
    quality ~name:"stock" ~gen:(stock elt) ~test ~is_minimal:minimal;
    quality ~name:"length-int" ~gen:(running elt) ~test ~is_minimal:minimal;
    quality ~name:"continuation" ~gen:(continuation elt) ~test ~is_minimal:minimal
  in
  run_case
    "length >= 3 (minimum [0;0;0])"
    int100
    ~test:(fun xs -> List.length xs < 3)
    ~minimal:(List.equal Int.equal [ 0; 0; 0 ]);
  run_case
    "sum >= 100 (minimum [100])"
    int1000
    ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
    ~minimal:(List.equal Int.equal [ 100 ]);
  run_case
    "hd = length (minimum [1])"
    (G.int_uniform_inclusive 0 50)
    ~test:(fun xs ->
      match xs with
      | [] -> true
      | x :: _ -> x <> List.length xs)
    ~minimal:(List.equal Int.equal [ 1 ]);
  run_case
    "ten strings (minimum ten empty strings)"
    G.string
    ~test:(fun xs -> List.length xs < 10)
    ~minimal:(fun xs -> List.length xs = 10 && List.for_all xs ~f:String.is_empty);

  Stdio.printf "\nGENERATION TAILS\n";
  generation_tail ~name:"stock strings" ~gen:(stock G.string) ~size:50 ~samples:10_000
    ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"running strings" ~gen:(running G.string) ~size:50 ~samples:10_000
    ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"continuation str" ~gen:(continuation G.string) ~size:50 ~samples:10_000
    ~measure:(List.sum (module Int) ~f:String.length);
  generation_tail ~name:"stock tree" ~gen:(tree stock) ~size:50 ~samples:10_000
    ~measure:tree_nodes;
  generation_tail ~name:"running tree" ~gen:(tree running) ~size:50 ~samples:10_000
    ~measure:tree_nodes;
  generation_tail ~name:"continuation tree" ~gen:(tree continuation) ~size:50 ~samples:10_000
    ~measure:tree_nodes
;;

open! Base

module G = Base_quickcheck.Generator

let check name condition = if not condition then failwith ("FAILED: " ^ name)

let generate gen ~size seed =
  G.generate gen ~size ~random:(Splittable_random.of_int seed)
;;

let counts ~gen ~size ~samples =
  let counts = Array.create ~len:(size + 1) 0 in
  for seed = 0 to samples - 1 do
    let length = List.length (generate gen ~size seed) in
    counts.(length) <- counts.(length) + 1
  done;
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
    else
      let expected_a = pooled *. total_a /. (total_a +. total_b) in
      let expected_b = pooled -. expected_a in
      result
      +. ((Float.of_int observed_a -. expected_a) **. 2. /. expected_a)
      +. ((Float.of_int observed_b -. expected_b) **. 2. /. expected_b))
;;

type tree =
  | Leaf
  | Node of tree list

let rec leaves = function
  | Leaf -> 1
  | Node children -> List.sum (module Int) children ~f:leaves
;;

let rec nodes = function
  | Leaf -> 1
  | Node children -> 1 + List.sum (module Int) children ~f:nodes
;;

type swallowed =
  | Only_leaf
  | Pair of swallowed * swallowed

let () =
  let samples = 50_000 in
  let size = 10 in
  let stock = counts ~gen:(G.list G.unit) ~size ~samples in
  let structural = counts ~gen:(G.list_structural G.unit) ~size ~samples in
  let statistic = chi_square stock structural in
  check "structural list preserves the stock marginal length distribution"
    Float.(statistic < 40.);

  let exact = generate (G.list_structural ~min_length:3 ~max_length:3 G.size) ~size:7 0 in
  check "fixed structural length respects both bounds"
    (List.equal Int.equal exact [ 7; 7; 7 ]);
  check "negative structural minimum is rejected"
    (Result.is_error
       (Result.try_with (fun () -> G.list_structural ~min_length:(-1) G.unit)));
  check "inconsistent structural bounds are rejected"
    (Result.is_error
       (Result.try_with (fun () ->
          G.list_structural ~min_length:2 ~max_length:1 G.unit)));
  let overflow_safe =
    generate
      (G.list_structural ~min_length:1 ~max_length:10 G.unit)
      ~size:Int.max_value
      0
  in
  check "overflowing min_length + size still respects max_length"
    (List.length overflow_safe >= 1 && List.length overflow_safe <= 10);

  let tree =
    G.recursive_with_max_leaves ~max_leaves:20 (G.return Leaf)
      ~f:(fun self -> G.map (G.list_structural self) ~f:(fun xs -> Node xs))
  in
  for seed = 0 to 4_999 do
    check "recursive generator respects its leaf cap"
      (leaves (generate tree ~size:50 seed) <= 20)
  done;

  (* OCaml has no BaseException-style class outside [try ... with _].  A
     malicious or defensive recursive layer can therefore swallow the private
     limit signal.  The generator tracks that event independently and rejects
     the whole attempt, so max_leaves=1 can never return [Pair]. *)
  let swallowed =
    G.recursive_with_max_leaves ~max_leaves:1 (G.return Only_leaf)
      ~f:(fun self ->
        G.create (fun ~size ~random ->
          let left = G.generate self ~size ~random in
          let right =
            match Result.try_with (fun () -> G.generate self ~size ~random) with
            | Ok value -> value
            | Error _ -> left
          in
          Pair (left, right)))
  in
  for seed = 0 to 999 do
    check "catch-all handlers cannot defeat the leaf cap"
      (match generate swallowed ~size:10 seed with
       | Only_leaf -> true
       | Pair _ -> false)
  done;
  let one_attempt =
    G.recursive_with_max_leaves ~max_leaves:1 ~max_attempts:1
      (G.return Only_leaf)
      ~f:(fun self -> G.map2 self self ~f:(fun left right -> Pair (left, right)))
  in
  check "attempt cap stops an over-cap draw"
    (List.exists (List.range 0 100) ~f:(fun seed ->
       Result.is_error (Result.try_with (fun () -> generate one_attempt ~size:10 seed))));
  check "non-positive leaf cap is rejected"
    (Result.is_error
       (Result.try_with (fun () ->
          G.recursive_with_max_leaves ~max_leaves:0 G.unit ~f:Fn.id)));
  check "non-positive attempt cap is rejected"
    (Result.is_error
       (Result.try_with (fun () ->
          G.recursive_with_max_leaves ~max_attempts:0 G.unit ~f:Fn.id)));

  let structural_int = G.list_structural (G.int_uniform_inclusive 0 1_000) in
  for seed = 0 to 49 do
    match
      Tape_engine.run structural_int ~seed:(seed * 1_000_003) ~count:200 ~size:10
        ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
    with
    | Tape_engine.Passed _ -> failwith "structural list did not find sum failure"
    | Tape_engine.Failed { minimal; _ } ->
      check "structural list shrinks sum failure to [100]"
        (List.equal Int.equal minimal [ 100 ])
  done;
  let shrink_tree =
    G.recursive_with_max_leaves ~max_leaves:100 (G.return Leaf)
      ~f:(fun self -> G.map (G.list_structural self) ~f:(fun xs -> Node xs))
  in
  for seed = 0 to 19 do
    match
      Tape_engine.run shrink_tree ~seed:(seed * 1_000_003) ~count:200 ~size:50
        ~budget:5_000 ~test:(fun tree -> nodes tree < 20)
    with
    | Tape_engine.Passed _ -> failwith "capped tree did not find node failure"
    | Tape_engine.Failed { minimal; _ } ->
      check "capped structural tree reaches the exact node boundary"
        (nodes minimal = 20)
  done;

  Stdlib.Printf.printf
    "structural generators: chi-square %.2f; generation and shrinking guards passed\n"
    statistic
;;

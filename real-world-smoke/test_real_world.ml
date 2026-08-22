open! Base
open Base_quickcheck.Export

module G = Base_quickcheck.Generator

let config name count =
  { Tape_test.default_config with
    seed = Deterministic ("real-world/" ^ name)
  ; test_count = count
  }
;;

let failf fmt = Printf.ksprintf failwith fmt

module Int_list = struct
  type t = int list [@@deriving quickcheck, sexp_of]
end

let drain_fheap values =
  let rec loop heap acc =
    match Fheap.pop heap with
    | None -> List.rev acc
    | Some (value, heap) -> loop heap (value :: acc)
  in
  loop (Fheap.of_list values ~compare:Int.compare) []
;;

let test_fheap_ordering () =
  Tape_test.run_exn
    ~config:(config "fheap-ordering" 1_000)
    ~report:`Silent
    ~f:(fun values ->
      let expected = List.sort values ~compare:Int.compare in
      let actual = drain_fheap values in
      if not (List.equal Int.equal actual expected)
      then
        failf
          "Fheap drain mismatch: expected %s, got %s"
          (Sexp.to_string ([%sexp_of: int list] expected))
          (Sexp.to_string ([%sexp_of: int list] actual)))
    (module Int_list)
;;

type heap_op =
  | Add of int
  | Pop
  | Clear
  | Copy_and_add of int
[@@deriving quickcheck, sexp_of]

module Heap_program = struct
  type t = heap_op list [@@deriving quickcheck, sexp_of]
end

let sorted = List.sort ~compare:Int.compare

let check_pairing_heap heap model =
  Pairing_heap.invariant ignore heap;
  let expected = sorted model in
  let actual = sorted (Pairing_heap.to_list heap) in
  if not (List.equal Int.equal actual expected)
  then
    failf
      "Pairing_heap contents mismatch: expected %s, got %s"
      (Sexp.to_string ([%sexp_of: int list] expected))
      (Sexp.to_string ([%sexp_of: int list] actual));
  if Pairing_heap.length heap <> List.length model
  then
    failf
      "Pairing_heap length mismatch: expected %d, got %d"
      (List.length model)
      (Pairing_heap.length heap);
  let expected_top = List.hd expected in
  if not (Option.equal Int.equal (Pairing_heap.top heap) expected_top)
  then failwith "Pairing_heap top disagrees with the reference model"
;;

let test_pairing_heap_model () =
  Tape_test.run_exn
    ~config:(config "pairing-heap-model" 1_000)
    ~report:`Silent
    ~f:(fun program ->
      let heap = Pairing_heap.create ~cmp:Int.compare () in
      let model = ref [] in
      List.iter program ~f:(fun op ->
        (match op with
         | Add value ->
           Pairing_heap.add heap value;
           model := value :: !model
         | Pop ->
           let expected, rest =
             match sorted !model with
             | [] -> (None, [])
             | value :: rest -> (Some value, rest)
           in
           let actual = Pairing_heap.pop heap in
           if not (Option.equal Int.equal actual expected)
           then failwith "Pairing_heap.pop disagrees with the reference model";
           model := rest
         | Clear ->
           Pairing_heap.clear heap;
           model := []
         | Copy_and_add value ->
           let copy = Pairing_heap.copy heap in
           Pairing_heap.add copy value;
           let expected_copy = value :: !model in
           check_pairing_heap copy expected_copy);
        check_pairing_heap heap !model))
    (module Heap_program)
;;

module V4_bits = struct
  type t = int32 [@@deriving quickcheck, sexp_of]
end

let test_ipaddr_round_trips () =
  Tape_test.run_exn
    ~config:(config "ipaddr-v4-round-trips" 2_000)
    ~report:`Silent
    ~f:(fun bits ->
      let address = Ipaddr.V4.of_int32 bits in
      let parsed = Ipaddr.V4.of_string (Ipaddr.V4.to_string address) in
      (match parsed with
       | Error (`Msg message) -> failf "Ipaddr rejected its own output: %s" message
       | Ok address' ->
         if not (Int32.equal (Ipaddr.V4.to_int32 address') bits)
         then failwith "Ipaddr text round-trip changed the address");
      let octets = Ipaddr.V4.to_octets address in
      match Ipaddr.V4.of_octets octets with
      | Error (`Msg message) -> failf "Ipaddr rejected its own octets: %s" message
      | Ok address' ->
        if not (Int32.equal (Ipaddr.V4.to_int32 address') bits)
        then failwith "Ipaddr octet round-trip changed the address")
    (module V4_bits)
;;

module Cstruct_input = struct
  type t =
    { payload : string
    ; cut_hint : int
    ; word : int64
    }
  [@@deriving sexp_of]

  let quickcheck_generator =
    G.map3 G.string (G.int_uniform_inclusive 0 1_000) G.int64
      ~f:(fun payload cut_hint word -> { payload; cut_hint; word })
  ;;

  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

let test_cstruct_views_and_endianness () =
  Tape_test.run_exn
    ~config:(config "cstruct-views-and-endianness" 1_000)
    ~report:`Silent
    ~f:(fun { Cstruct_input.payload; cut_hint; word } ->
      let padded = "prefix" ^ payload ^ "suffix" in
      let view = Cstruct.of_string ~off:6 ~len:(String.length payload) padded in
      if not (String.equal (Cstruct.to_string view) payload)
      then failwith "Cstruct.of_string selected the wrong view";
      let cut = cut_hint % (String.length payload + 1) in
      let left, right = Cstruct.split view cut in
      if not (String.equal (Cstruct.to_string (Cstruct.append left right)) payload)
      then failwith "Cstruct split/append failed to reconstruct the input";
      let binary = Cstruct.create 16 in
      Cstruct.BE.set_uint64 binary 3 word;
      if not (Int64.equal (Cstruct.BE.get_uint64 binary 3) word)
      then failwith "Cstruct big-endian uint64 round-trip changed the word";
      Cstruct.LE.set_uint64 binary 5 word;
      if not (Int64.equal (Cstruct.LE.get_uint64 binary 5) word)
      then failwith "Cstruct little-endian uint64 round-trip changed the word")
    (module Cstruct_input)
;;

let test_counterexample_quality () =
  match
    Tape_test.result
      ~config:(config "fheap-does-not-preserve-insertion-order" 1_000)
      ~report:`Silent
      ~f:(fun values ->
        if List.equal Int.equal (drain_fheap values) values
        then Ok ()
        else Error "a priority heap does not preserve insertion order")
      (module Int_list)
  with
  | Ok () -> failwith "positive control found no out-of-order input"
  | Error (minimal, _) ->
    if List.length minimal <> 2
    then
      failf
        "positive control did not shrink to two elements: %s"
        (Sexp.to_string ([%sexp_of: int list] minimal));
    if List.equal Int.equal (drain_fheap minimal) minimal
    then failwith "reported positive-control example no longer fails";
    let tiny = List.for_all minimal ~f:(fun value -> value >= -1 && value <= 1) in
    Stdio.printf
      "%s real-world positive control: insertion-order claim shrank to %s\n"
      (if tiny then "ok " else "gap")
      (Sexp.to_string ([%sexp_of: int list] minimal))
;;

let () =
  test_fheap_ordering ();
  test_pairing_heap_model ();
  test_ipaddr_round_trips ();
  test_cstruct_views_and_endianness ();
  test_counterexample_quality ();
  Stdio.print_endline "test_real_world: all external-library properties passed"
;;

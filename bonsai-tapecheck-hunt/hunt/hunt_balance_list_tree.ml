open! Core
open Base_quickcheck.Export

(* Core v0.17 does not export [( << )] (it lives in
   core_kernel.composition_infix, which nothing here opens). *)
let ( << ) f g x = f (g x)

(* Bias [n] towards small positive values so the [Ok] path is well exercised; the
   error biconditional below still sees plenty of invalid inputs via the second
   module further down. *)
module Validish_input = struct
  type t =
    { n : int
    ; xs : int list
    }
  [@@deriving sexp_of]

  let quickcheck_generator =
    Base_quickcheck.Generator.both
      (Base_quickcheck.Generator.int_uniform_inclusive 1 8)
      (Base_quickcheck.Generator.list (Base_quickcheck.Generator.int_inclusive (-100) 100))
    |> Base_quickcheck.Generator.map ~f:(fun (n, xs) -> { n; xs })
  ;;

  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

module Any_input = struct
  type t =
    { n : int
    ; xs : int list
    }
  [@@deriving quickcheck, sexp_of]
end

let is_valid_input ~n ~xs =
  (not (List.is_empty xs)) && n >= 1 && (n > 1 || List.length xs = 1)
;;

(* [balance] errors exactly on the inputs its mli documents as invalid. *)
let prop_error_iff_invalid { Validish_input.n; xs } =
  match Balance_list_tree.balance ~n xs with
  | Error _ ->
    if is_valid_input ~n ~xs
    then Error (Error.of_string "errored on valid input")
    else Ok ()
  | Ok _ ->
    if is_valid_input ~n ~xs
    then Ok ()
    else Error (Error.of_string "accepted invalid input")
;;

let flatten tree =
  let rec aux tree acc =
    match tree with
    | Balance_list_tree.Leaf x -> x :: acc
    | Node children ->
      Nonempty_list.fold children ~init:acc ~f:(fun acc child -> aux child acc)
  in
  List.rev (aux tree [])
;;

(* On valid inputs: the leaves are exactly the input list, in order; every node
   has at most [n] children; no [Node] wraps a single [Leaf]. *)
let prop_shape { Validish_input.n; xs } =
  match Balance_list_tree.balance ~n xs with
  | Error _ -> Ok () (* error behavior is covered by [prop_error_iff_invalid] *)
  | Ok tree ->
    if not ([%equal: int list] (flatten tree) xs)
    then Error (Error.of_string "leaves do not reproduce the input list")
    else (
      let rec check tree =
        match tree with
        | Balance_list_tree.Leaf _ -> Ok ()
        | Node children ->
          if Nonempty_list.length children > n
          then Error (Error.of_string "node with more than n children")
          else (
            match children with
            | [ Leaf _ ] -> Error (Error.of_string "node wrapping a single leaf")
            | _ ->
              Nonempty_list.fold children ~init:(Ok ()) ~f:(fun acc child ->
                match acc with
                | Error _ -> acc
                | Ok () -> check child))
      in
      check tree)
;;

let () =
  Tape_test.run_exn
    ~f:(Or_error.ok_exn << prop_error_iff_invalid)
    (module Validish_input);
  Tape_test.run_exn
    ~f:
      (Or_error.ok_exn
       << fun { Any_input.n; xs } -> prop_error_iff_invalid { Validish_input.n; xs })
    (module Any_input);
  Tape_test.run_exn ~f:(Or_error.ok_exn << prop_shape) (module Validish_input)
;;

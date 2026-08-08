open! Core
open Base_quickcheck.Export

(* Core v0.17 does not export [( << )] (it lives in
   core_kernel.composition_infix, which nothing here opens). *)
let ( << ) f g x = f (g x)

module Int_list = struct
  type t = int list [@@deriving quickcheck, sexp_of]
end

module Int_pair_list = struct
  type t = (int * int) list [@@deriving quickcheck, sexp_of]
end

module Depth = struct
  type t = int [@@deriving sexp_of]

  let quickcheck_generator = Base_quickcheck.Generator.int_uniform_inclusive 0 200_000
  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

(* [all] of [return]s is the identity on lists. *)
let prop_all_return (xs : int list) =
  let result = Trampoline.run (Trampoline.all (List.map xs ~f:Trampoline.return)) in
  if [%equal: int list] result xs then Ok () else Error (Error.of_string "all/return mismatch")
;;

(* [all_map] of [return]s is the identity on maps. *)
let prop_all_map_return (pairs : (int * int) list) =
  let deduped =
    List.dedup_and_sort pairs ~compare:(fun (k1, _) (k2, _) -> Int.compare k1 k2)
  in
  let map = Map.of_alist_exn (module Int) deduped in
  let result =
    Trampoline.run (Trampoline.all_map (Map.map map ~f:Trampoline.return))
  in
  (* ppx_compare expands a 3-parameter [Map.t] to [Map.equal] with one
     equality per type parameter, but [Map.equal] (v0.17 and bleeding
     alike) takes only the value equality -- so spell it out. *)
  if Map.equal [%equal: int] result map
  then Ok ()
  else Error (Error.of_string "all_map/return mismatch")
;;

(* A left-nested bind chain of depth [d] computes [d] — and, being the whole point
   of the library, does not stack overflow for large [d]. The builder is
   tail-recursive; only [Trampoline.run] is under test. *)
let prop_deep_bind_chain (d : int) =
  let rec build d acc =
    if d = 0
    then acc
    else
      build
        (d - 1)
        (let%bind.Trampoline x = acc in
         Trampoline.return (x + 1))
  in
  let result = Trampoline.run (build d (Trampoline.return 0)) in
  if result = d then Ok () else Error (Error.of_string "deep bind chain mismatch")
;;

(* [lazy_] defers but does not change the result. *)
let prop_lazy (xs : int list) =
  let rec nest depth acc =
    if depth = 0 then acc else nest (depth - 1) (Trampoline.lazy_ (lazy acc))
  in
  let result = Trampoline.run (nest (List.length xs) (Trampoline.return xs)) in
  if [%equal: int list] result xs then Ok () else Error (Error.of_string "lazy_ mismatch")
;;

let () =
  Tape_test.run_exn ~f:(Or_error.ok_exn << prop_all_return) (module Int_list);
  Tape_test.run_exn ~f:(Or_error.ok_exn << prop_all_map_return) (module Int_pair_list);
  Tape_test.run_exn ~f:(Or_error.ok_exn << prop_deep_bind_chain) (module Depth);
  Tape_test.run_exn ~f:(Or_error.ok_exn << prop_lazy) (module Int_list)
;;

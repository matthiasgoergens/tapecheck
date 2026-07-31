(* Does the ~85%-bookkeeping finding hold for realistic generator
   shapes, or is it an artefact of measuring G.list alone?

   Shapes are reconstructed from types that carry [@@deriving quickcheck]
   in janestreet/core rather than invented: Blang.t (a recursive boolean
   expression, core/src/blang.ml), records, assoc maps, strings, and
   tuples of lists. They are RECONSTRUCTIONS, not core's own derived
   generators -- core/test does not build outside Jane Street (capsule,
   ppx_bin_and_sexp_digest, unboxed_test_harness are unpublished), so the
   real generators are not reachable. The shapes are faithful; the exact
   combinator choices may differ from what the deriver emits. *)
open Base
module G = Base_quickcheck.Generator

let count img =
  Array.length img.Tape.main
  + Array.fold img.Tape.streams ~init:0 ~f:(fun a (_, c) -> a + Array.length c)

(* Blang: And/Or/Not/Base over a small base type. *)
type blang =
  | Base of int
  | Not of blang
  | And of blang * blang
  | Or of blang * blang

let rec blang_gen depth =
  let open G.Let_syntax in
  if depth <= 0 then
    let%map v = G.int_uniform_inclusive 0 100 in
    Base v
  else
    let%bind tag = G.int_uniform_inclusive 0 3 in
    match tag with
    | 0 ->
      let%map v = G.int_uniform_inclusive 0 100 in
      Base v
    | 1 ->
      let%map b = blang_gen (depth - 1) in
      Not b
    | 2 ->
      let%bind a = blang_gen (depth - 1) in
      let%map b = blang_gen (depth - 1) in
      And (a, b)
    | _ ->
      let%bind a = blang_gen (depth - 1) in
      let%map b = blang_gen (depth - 1) in
      Or (a, b)

let rec blang_nodes = function
  | Base _ -> 1
  | Not b -> 1 + blang_nodes b
  | And (a, b) | Or (a, b) -> 1 + blang_nodes a + blang_nodes b

let probe ~name ~gen ~data_units ~size =
  let choices = ref 0 and units = ref 0 and n = ref 0 in
  for t = 0 to 199 do
    match
      Tape_engine.run gen ~test:(fun _ -> false) ~seed:(t * 7919) ~count:1
        ~size ~budget:0
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { image; original; _ } ->
      Int.incr n;
      choices := !choices + count image;
      units := !units + data_units original
  done;
  if !n > 0 then begin
    let c = Float.of_int !choices /. Float.of_int !n in
    let u = Float.of_int !units /. Float.of_int !n in
    Stdio.printf "  %-26s %6.1f choices, %5.1f data units, %5.2f choices/unit\n"
      name c u (c /. Float.max 1. u)
  end

let () =
  Stdio.printf "tape choices per unit of actual data, ~size=10\n";
  probe ~name:"int list (the baseline)"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~data_units:List.length ~size:10;
  probe ~name:"Blang-like tree (depth 4)" ~gen:(blang_gen 4)
    ~data_units:blang_nodes ~size:10;
  probe ~name:"string"
    ~gen:(G.string_of G.char_lowercase)
    ~data_units:String.length ~size:10;
  probe ~name:"assoc map (int -> int)"
    ~gen:
      (G.list
         (G.both (G.int_uniform_inclusive 0 1000)
            (G.int_uniform_inclusive 0 1000)))
    ~data_units:List.length ~size:10;
  probe ~name:"record: 4 scalar fields"
    ~gen:
      (let open G.Let_syntax in
       let%bind a = G.int_uniform_inclusive 0 1000 in
       let%bind b = G.bool in
       let%bind c = G.int_uniform_inclusive 0 1000 in
       let%map d = G.char_lowercase in
       (a, b, c, d))
    ~data_units:(fun _ -> 4) ~size:10;
  probe ~name:"list of lists"
    ~gen:(G.list (G.list (G.int_uniform_inclusive 0 100)))
    ~data_units:(fun ls -> List.sum (module Int) ls ~f:List.length)
    ~size:10;
  probe ~name:"option list"
    ~gen:(G.list (G.option (G.int_uniform_inclusive 0 1000)))
    ~data_units:List.length ~size:10

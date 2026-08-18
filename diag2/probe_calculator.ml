(* Paired migration probe for the calculator challenge.  This deliberately
   measures deterministic discovery and shrinking work, not wall-clock time:
   one experimental unit is a seed used by both generator arms. *)
open Base
module G = Base_quickcheck.Generator

type expr = Lit of int | Add of expr * expr | Div of expr * expr

let rec render = function
  | Lit n -> Int.to_string n
  | Add (a, b) -> Printf.sprintf "('+', %s, %s)" (render a) (render b)
  | Div (a, b) -> Printf.sprintf "('/', %s, %s)" (render a) (render b)

let rec div_subterms = function
  | Lit _ -> true
  | Div (_, Lit 0) -> false
  | Add (a, b) | Div (a, b) -> div_subterms a && div_subterms b

let rec evaluate = function
  | Lit n -> n
  | Add (a, b) -> evaluate a + evaluate b
  | Div (a, b) -> evaluate a / evaluate b

let stock =
  G.recursive_union
    [ G.map G.int ~f:(fun n -> Lit n) ]
    ~f:(fun self ->
      [ G.map (G.both self self) ~f:(fun (a, b) -> Add (a, b))
      ; G.map (G.both self self) ~f:(fun (a, b) -> Div (a, b))
      ])

let structural =
  G.recursive_with_max_leaves
    (G.map G.int ~f:(fun n -> Lit n))
    ~f:(fun self ->
      G.union
        [ G.map (G.both self self) ~f:(fun (a, b) -> Add (a, b))
        ; G.map (G.both self self) ~f:(fun (a, b) -> Div (a, b))
        ])

let test e =
  if not (div_subterms e) then raise Tape_stats.Invalid_example;
  match evaluate e with
  | (_ : int) -> true
  | exception Division_by_zero -> false

let rec nodes = function
  | Lit _ -> 1
  | Add (a, b) | Div (a, b) -> 1 + nodes a + nodes b

type found =
  { exact : bool
  ; attempts : int
  ; nodes : int
  ; rendered_length : int
  }

type outcome =
  | Not_found
  | Found of found

let expected = "('/', 0, ('+', 0, 0))"

let run gen ~seed ~count =
  match Tape_engine.run gen ~test ~seed ~count ~size:8 ~budget:20_000 with
  | Tape_engine.Passed _ -> Not_found
  | Tape_engine.Failed { minimal; attempts; _ } ->
    let rendered = render minimal in
    Found
      { exact = String.equal rendered expected
      ; attempts
      ; nodes = nodes minimal
      ; rendered_length = String.length rendered
      }

let print_observation ~unit ~arm = function
  | Not_found -> Stdio.printf "%d\t%s\t0\t0\t0\t0\t0\n%!" unit arm
  | Found { exact; attempts; nodes; rendered_length } ->
    Stdio.printf "%d\t%s\t1\t%d\t%d\t%d\t%d\n%!"
      unit arm (Bool.to_int exact) attempts nodes rendered_length

let summarise name outcomes =
  let found = List.filter_map outcomes ~f:(function Not_found -> None | Found x -> Some x) in
  let n = List.length found in
  let exact = List.count found ~f:(fun x -> x.exact) in
  let mean field =
    if n = 0
    then 0.
    else Float.of_int (List.sum (module Int) found ~f:field) /. Float.of_int n
  in
  Stdio.eprintf
    "%s: found %d/%d, exact %d/%d; mean attempts %.1f, nodes %.1f, rendered bytes %.1f\n%!"
    name n (List.length outcomes) exact n
    (mean (fun x -> x.attempts))
    (mean (fun x -> x.nodes))
    (mean (fun x -> x.rendered_length))

let () =
  let runs =
    match Stdlib.Sys.getenv_opt "TAPECHECK_PROBE_RUNS" with
    | None -> 100
    | Some value -> Int.of_string value
  in
  let count =
    match Stdlib.Sys.getenv_opt "TAPECHECK_PROBE_COUNT" with
    | None -> 20_000
    | Some value -> Int.of_string value
  in
  let stock_outcomes = ref [] in
  let structural_outcomes = ref [] in
  Stdio.printf "unit\tarm\tfound\texact\tattempts\tnodes\trendered_bytes\n%!";
  for unit = 0 to runs - 1 do
    let seed = (unit * 2_654_435_761) land 0x3FFF_FFFF in
    (* Alternate arm order within consecutive seed blocks, so later additions
       of timing measurements do not silently confound arm with machine drift. *)
    let first_name, first_gen, second_name, second_gen =
      if unit land 1 = 0
      then ("stock", stock, "structural", structural)
      else ("structural", structural, "stock", stock)
    in
    let first_outcome = run first_gen ~seed ~count in
    let second_outcome = run second_gen ~seed ~count in
    print_observation ~unit ~arm:first_name first_outcome;
    print_observation ~unit ~arm:second_name second_outcome;
    let add name outcome =
      if String.equal name "stock"
      then stock_outcomes := outcome :: !stock_outcomes
      else structural_outcomes := outcome :: !structural_outcomes
    in
    add first_name first_outcome;
    add second_name second_outcome
  done;
  let stock_outcomes = List.rev !stock_outcomes in
  let structural_outcomes = List.rev !structural_outcomes in
  summarise "stock" stock_outcomes;
  summarise "structural" structural_outcomes;
  let exact = function Found { exact; _ } -> exact | Not_found -> false in
  let stock_to_structural =
    List.count (List.zip_exn stock_outcomes structural_outcomes)
      ~f:(fun (a, b) -> (not (exact a)) && exact b)
  in
  let structural_to_stock =
    List.count (List.zip_exn stock_outcomes structural_outcomes)
      ~f:(fun (a, b) -> exact a && not (exact b))
  in
  Stdio.eprintf "paired exact transitions: stock->structural %d, structural->stock %d\n%!"
    stock_to_structural structural_to_stock

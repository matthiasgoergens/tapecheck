(* Matched-seed comparison of the ordinary and opt-in structural list
   generators.  The arms intentionally do not share an original value:
   [list_structural] changes the generator representation and element-size
   contract, so this measures each complete generator-plus-tape-shrinker arm. *)

open! Base
open Stdio
module G = Base_quickcheck.Generator

let trials = 100
let size = 10
let cases_per_trial = 200
let shrink_budget = 5_000

let observations =
  match Array.to_list (Sys.get_argv ()) with
  | [ _ ] -> false
  | [ _; "--observations" ] -> true
  | _ -> failwith "usage: structural_table.exe [--observations]"

type result =
  { found : bool
  ; fully_minimal : bool
  ; calls : int
  ; original_length : int
  ; original : string
  ; minimal : string
  }

let run_one gen ~test ~is_minimal ~seed =
  match
    Tape_engine.run gen ~test ~seed ~count:cases_per_trial ~size
      ~budget:shrink_budget
  with
  | Tape_engine.Passed _ ->
    { found = false
    ; fully_minimal = false
    ; calls = 0
    ; original_length = -1
    ; original = "-"
    ; minimal = "-"
    }
  | Tape_engine.Failed { original; minimal; attempts; _ } ->
    { found = true
    ; fully_minimal = is_minimal minimal
    ; calls = attempts
    ; original_length = List.length original
    ; original = Sexp.to_string ([%sexp_of: int list] original)
    ; minimal = Sexp.to_string ([%sexp_of: int list] minimal)
    }

type stats =
  { mutable found : int
  ; mutable fully_minimal : int
  ; mutable calls : int
  }

let create_stats () = { found = 0; fully_minimal = 0; calls = 0 }

let add (stats : stats) (result : result) =
  if result.found then begin
    stats.found <- stats.found + 1;
    stats.calls <- stats.calls + result.calls
  end;
  if result.fully_minimal then
    stats.fully_minimal <- stats.fully_minimal + 1

let print_observation ~property ~seed ~arm (result : result) =
  printf "%s\t%d\t%s\t%b\t%b\t%d\t%d\t%s\t%s\n" property seed arm
    result.found result.fully_minimal result.calls result.original_length
    (String.escaped result.original) (String.escaped result.minimal)

let print_stats arm (stats : stats) =
  let mean =
    if stats.found = 0
    then 0.
    else Float.of_int stats.calls /. Float.of_int stats.found
  in
  printf
    "  %-10s found %3d/%d, fully minimal %3d/%d, mean %6.2f shrink calls\n"
    arm stats.found trials stats.fully_minimal trials mean

let row ~id ~name ~ordinary ~structural ~test ~is_minimal =
  if not observations then printf "%s -- %d seeds\n" name trials;
  let ordinary_stats = create_stats () in
  let structural_stats = create_stats () in
  for trial = 0 to trials - 1 do
    let seed = trial * 1_000_003 in
    let ordinary_result = run_one ordinary ~test ~is_minimal ~seed in
    let structural_result = run_one structural ~test ~is_minimal ~seed in
    add ordinary_stats ordinary_result;
    add structural_stats structural_result;
    if observations then begin
      print_observation ~property:id ~seed ~arm:"ordinary" ordinary_result;
      print_observation ~property:id ~seed ~arm:"structural" structural_result
    end
  done;
  if not observations then begin
    print_stats "ordinary" ordinary_stats;
    print_stats "structural" structural_stats;
    printf "\n"
  end

let () =
  if observations then
    printf
      "property\tseed\tarm\tfound\tfully_minimal\tshrink_calls\toriginal_length\toriginal\tresult\n";
  row ~id:"list_length" ~name:"int list, fail iff length >= 3"
    ~ordinary:(G.list (G.int_uniform_inclusive 0 100))
    ~structural:(G.list_structural (G.int_uniform_inclusive 0 100))
    ~test:(fun xs -> List.length xs < 3)
    ~is_minimal:(fun xs -> List.equal Int.equal xs [ 0; 0; 0 ]);
  row ~id:"list_sum" ~name:"int list, fail iff sum >= 100"
    ~ordinary:(G.list (G.int_uniform_inclusive 0 1_000))
    ~structural:(G.list_structural (G.int_uniform_inclusive 0 1_000))
    ~test:(fun xs -> List.sum (module Int) xs ~f:Fn.id < 100)
    ~is_minimal:(fun xs -> List.equal Int.equal xs [ 100 ]);
  row ~id:"self_length"
    ~name:"self_len: fails iff l <> [] && hd l = length l"
    ~ordinary:(G.list (G.int_uniform_inclusive 0 50))
    ~structural:(G.list_structural (G.int_uniform_inclusive 0 50))
    ~test:(fun xs ->
      not (match xs with [] -> false | head :: _ -> head = List.length xs))
    ~is_minimal:(fun xs -> List.equal Int.equal xs [ 1 ])

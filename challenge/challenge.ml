(* The Shrinking Challenge (github.com/jlink/shrinking-challenge) in
   tapecheck.

   A cross-language benchmark suite for shrinkers, with published
   reports from ten libraries -- Hypothesis, jqwik, PropEr, FsCheck,
   fast-check, CsCheck, Americium, elm-test, rapid, Exhaust. There is
   no OCaml entry.

   Their report format is the right one and is copied here: for each
   challenge, what the shrinker NORMALISES to (does it reach the same
   canonical answer regardless of starting point?) and what that costs
   in test evaluations. Quality and cost together, which is the same
   discipline test_regression/ holds us to internally.

   Note on their published Hypothesis numbers: they were generated with
   Hypothesis 5.23.11, in 2020. Quoting them against a 2026 tapecheck
   would be unfair in both directions, so the comparison run re-measures
   current Hypothesis under the same protocol rather than citing the
   repo's table. The expected answers below, however, come from the
   challenge specs themselves and are stable. *)
open Base
module G = Base_quickcheck.Generator

let runs = 100

type outcome =
  { normal : string        (* rendered minimal example *)
  ; attempts : int
  }

let bench (type a) ~name ~(gen : a Base_quickcheck.Generator.t)
    ~(test : a -> bool) ~(render : a -> string) ~expected ?(count = 1_000_000)
    ?(budget = 20_000) () =
  let outcomes = ref [] in
  let not_found = ref 0 in
  for t = 0 to runs - 1 do
    match
      Tape_engine.run gen ~test ~seed:(t * 7919) ~count ~size:30 ~budget
    with
    | Tape_engine.Passed _ -> Int.incr not_found
    | Tape_engine.Failed { minimal; attempts; _ } ->
      outcomes := { normal = render minimal; attempts } :: !outcomes
  done;
  let os = !outcomes in
  let n = List.length os in
  let hits = List.count os ~f:(fun o -> String.equal o.normal expected) in
  let tbl = Hashtbl.create (module String) in
  List.iter os ~f:(fun o ->
    Hashtbl.update tbl o.normal ~f:(function None -> 1 | Some c -> c + 1));
  let distinct = Hashtbl.length tbl in
  let attempts = List.map os ~f:(fun o -> o.attempts) in
  let mean =
    if n = 0 then 0. else Float.of_int (List.sum (module Int) attempts ~f:Fn.id) /. Float.of_int n
  in
  let lo = List.min_elt attempts ~compare:Int.compare |> Option.value ~default:0 in
  let hi = List.max_elt attempts ~compare:Int.compare |> Option.value ~default:0 in
  Stdio.printf "## %s\n\n" name;
  Stdio.printf "  expected      %s\n" expected;
  Stdio.printf "  normalised    %d/%d runs (%d distinct answers)\n" hits n distinct;
  if !not_found > 0 then
    Stdio.printf "  NOT FOUND     %d/%d runs failed to find any counterexample\n"
      !not_found runs;
  Stdio.printf "  evaluations   %d..%d during shrinking, mean %.2f\n" lo hi mean;
  (* The most common answers, so a miss is legible rather than just a
     number: seeing WHAT it settles on says which pass is absent. *)
  let top =
    Hashtbl.to_alist tbl
    |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
    |> fun l -> List.take l 4
  in
  List.iter top ~f:(fun (k, c) ->
    Stdio.printf "      %3d x  %s%s\n" c k
      (if String.equal k expected then "   <- expected" else ""));
  Stdio.printf "\n";
  (name, hits, n, mean)

let string_of_int_list l =
  "[" ^ String.concat ~sep:", " (List.map l ~f:Int.to_string) ^ "]"

let string_of_int_list_list l =
  "[" ^ String.concat ~sep:", " (List.map l ~f:string_of_int_list) ^ "]"

(* ---- reverse: reversing a list gives the same list ---- *)
let reverse () =
  bench ~name:"reverse" ~gen:(G.list G.int)
    ~test:(fun l -> List.equal Int.equal (List.rev l) l)
    ~render:string_of_int_list ~expected:"[0, 1]" ()

(* ---- large union list: fewer than 5 distinct integers overall ---- *)
let large_union_list () =
  bench ~name:"large_union_list" ~gen:(G.list (G.list G.int))
    ~test:(fun ls ->
      let s = Hash_set.create (module Int) in
      List.iter ls ~f:(List.iter ~f:(Hash_set.add s));
      Hash_set.length s < 5)
    ~render:string_of_int_list_list ~expected:"[[0, 1, -1, 2, -2]]" ()

(* ---- lengthlist: n then a list of exactly n elements ---- *)
let lengthlist () =
  bench ~name:"lengthlist"
    ~gen:
      (G.bind (G.int_uniform_inclusive 1 100) ~f:(fun n ->
         G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:n))
    ~test:(fun l ->
      match List.max_elt l ~compare:Int.compare with
      | None -> true
      | Some m -> m < 900)
    ~render:string_of_int_list ~expected:"[900]" ()

(* ---- distinct: a list with at least three distinct elements ---- *)
let distinct () =
  bench ~name:"distinct" ~gen:(G.list G.int)
    ~test:(fun l ->
      let s = Hash_set.create (module Int) in
      List.iter l ~f:(Hash_set.add s);
      Hash_set.length s < 3)
    ~render:string_of_int_list ~expected:"[0, 1, -1]" ()

(* ---- difference: three variants, all needing a dependency between
       two separately-drawn integers to be maintained ---- *)
let difference ~name ~bad ~expected =
  bench ~name
    ~gen:(G.both (G.int_uniform_inclusive 0 1_000_000) (G.int_uniform_inclusive 0 1_000_000))
    ~test:(fun (a, b) -> a < 10 || not (bad (abs (a - b))))
    ~render:(fun (a, b) -> Printf.sprintf "[%d, %d]" a b)
    ~expected ()

let () =
  Stdio.printf
    "# The Shrinking Challenge, tapecheck\n\n\
     %d runs per challenge; \"normalised\" counts runs reaching the answer the\n\
     challenge specifies as smallest.\n\n"
    runs;
  let results =
    [ reverse ()
    ; large_union_list ()
    ; lengthlist ()
    ; distinct ()
    ; difference ~name:"difference_must_not_be_zero" ~bad:(fun d -> d = 0)
        ~expected:"[10, 10]"
    ; difference ~name:"difference_must_not_be_small"
        ~bad:(fun d -> d >= 1 && d <= 4) ~expected:"[10, 6]"
    ; difference ~name:"difference_must_not_be_one" ~bad:(fun d -> d = 1)
        ~expected:"[10, 9]"
    ]
  in
  Stdio.printf "## Summary\n\n";
  Stdio.printf "| challenge | normalised | mean evaluations |\n";
  Stdio.printf "|---|---|---|\n";
  List.iter results ~f:(fun (name, hits, n, mean) ->
    Stdio.printf "| %s | %d/%d | %.1f |\n" name hits n mean)

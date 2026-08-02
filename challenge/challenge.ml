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

(* Run count is configurable because 100 is too thin for the rates this
   suite produces. A 17/100 has a 95% Wilson interval of roughly
   [11, 26], so the stock-vs-patch bound5 comparison (17 vs 7) sits at
   about two sigma -- suggestive, not settled. Set TAPECHECK_RUNS to
   widen it. Seeds are spread by an odd multiplier well away from any
   power of two rather than by a small stride. *)
let runs =
  match Stdlib.Sys.getenv_opt "TAPECHECK_RUNS" with
  | Some s -> (try Int.of_string s with _ -> 100)
  | None -> 100

let seed_of t = (t * 2_654_435_761) land 0x3FFF_FFFF

(* Wilson score interval for a binomial proportion: behaves sanely at
   0 and at n, which the normal approximation does not, and this suite
   has plenty of both. *)
let wilson ~hits ~n =
  if n = 0 then (0., 0.)
  else begin
    let n' = Float.of_int n and x = Float.of_int hits in
    let z = 1.96 in
    let p = x /. n' in
    let denom = 1. +. (z *. z /. n') in
    let centre = (p +. (z *. z /. (2. *. n'))) /. denom in
    let half =
      z
      *. Float.sqrt ((p *. (1. -. p) /. n') +. (z *. z /. (4. *. n' *. n')))
      /. denom
    in
    (Float.max 0. ((centre -. half) *. 100.), Float.min 100. ((centre +. half) *. 100.))
  end

type outcome =
  { normal : string        (* rendered minimal example *)
  ; attempts : int
  }

let bench (type a) ~name ~(gen : a Base_quickcheck.Generator.t)
    ~(test : a -> bool) ~(render : a -> string) ~expected ?(count = 1_000_000)
    ?(budget = 20_000) ?(size = 30) () =
  let outcomes = ref [] in
  let not_found = ref 0 in
  for t = 0 to runs - 1 do
    match
      Tape_engine.run gen ~test ~seed:(seed_of t) ~count ~size ~budget
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
  Stdio.printf "## %s\n\n%!" name;
  Stdio.printf "  expected      %s\n" expected;
  let lo_ci, hi_ci = wilson ~hits ~n in
  Stdio.printf "  normalised    %d/%d runs = %.1f%% [95%% CI %.1f-%.1f] (%d distinct)\n"
    hits n
    (100. *. Float.of_int hits /. Float.of_int (Int.max 1 n))
    lo_ci hi_ci distinct;
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
  Stdio.printf "\n%!";
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

(* ---- deletion, nestedlists, coupling ----

   Three of the eleven upstream challenges were never ported. Found by
   diffing shrinking-challenge/challenges/ against this file rather than
   by inventing new cases, and they are the ones aimed squarely at what
   a delete-and-lower shrinker is bad at. Definitions taken from the
   fast-check reference implementations so the comparison is like for
   like; expected answers are the upstream ones.

   The fourth, binheap, is not here: it needs a heap datatype and is a
   GENERATION challenge rather than a shrinking one ("most libraries
   seem to never find the smallest example... small examples are too
   sparse"). Worth its own entry, not a line in this list. *)

(* "Remove an element from a list and it is no longer in the list",
   with a remove that only drops the FIRST occurrence -- so it fails
   exactly on duplicates. Upstream: "shrinking duplicates
   simultaneously is something that most property-based testing
   libraries can't do." Expected ([0, 0], 0). *)
let deletion () =
  bench ~name:"deletion"
    ~gen:(G.both (G.list G.int) (G.int_uniform_inclusive 0 10))
    ~test:(fun (ls, i) ->
      Tape_stats.assume (i < List.length ls);
      let x = List.nth_exn ls i in
      let without =
        List.filteri ls ~f:(fun j _ -> j <> i)
      in
      not (List.mem without x ~equal:Int.equal))
    ~render:(fun (ls, i) ->
      Printf.sprintf "(%s, %d)" (string_of_int_list ls) i)
    ~expected:"([0, 0], 0)" ()

(* Sum of inner lengths must be <= 10. Upstream: "lots of local minima
   under pure deletion based approaches -- [[0], ..., [0]] and
   [[0, ..., 0]] are both minima for anything that can only make
   individual elements smaller." Hypothesis and jqwik reach the single
   11-element list reliably. *)
let nestedlists () =
  bench ~name:"nestedlists"
    ~gen:(G.list (G.list (G.return 0)))
    ~test:(fun ls -> List.sum (module Int) ls ~f:List.length <= 10)
    ~render:(fun ls ->
      "["
      ^ String.concat ~sep:", " (List.map ls ~f:string_of_int_list)
      ^ "]")
    ~expected:"[[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]" ()

(* Elements coupled to their own index: for each i with j = ls.(i) and
   i <> j, ls.(j) must not be i. Every element must be a valid index.
   Expected [1, 0]. *)
let coupling () =
  bench ~name:"coupling"
    ~gen:(G.list (G.int_uniform_inclusive 0 10))
    ~test:(fun ls ->
      let n = List.length ls in
      Tape_stats.assume (List.for_all ls ~f:(fun v -> v < n));
      let a = Array.of_list ls in
      Array.for_alli a ~f:(fun i j -> i = j || a.(j) <> i))
    ~render:string_of_int_list ~expected:"[1, 0]" ()

(* ---- binheap: the GENERATION challenge ----

   The eleventh upstream case, and different in kind from the rest.
   Upstream: "most libraries seem to never find the smallest example
   here... small examples are 'too sparse', so it's very hard to find
   one by luck." The difficulty is in FINDING a counterexample, not in
   reducing one, which makes it the challenge that bears on the budget
   that actually matters -- generation runs on every CI job and usually
   finds nothing.

   From QuickCheck's test suite via the SmartCheck paper. Definition
   follows the elm-test reference (depth 4, optional children); the
   merge is deliberately wrong, so a heap whose toList disagrees with
   the sorted wrongToSortedList is a counterexample. *)
type heap = Heap of int * heap option * heap option

let rec render_heap (Heap (n, l, r)) =
  Printf.sprintf "(%d, %s, %s)" n (render_heap_opt l) (render_heap_opt r)

and render_heap_opt = function
  | None -> "None"
  | Some h -> render_heap h

let rec heap_gen depth =
  if depth <= 0 then G.map G.int ~f:(fun i -> Heap (i, None, None))
  else
    G.map3 G.int
      (G.option (heap_gen (depth - 1)))
      (G.option (heap_gen (depth - 1)))
      ~f:(fun n l r -> Heap (n, l, r))

let heap_to_list h =
  let rec go acc stack =
    match stack with
    | [] -> List.rev acc
    | Heap (n, l, r) :: hs ->
      go (n :: acc) (List.filter_opt [ l; r ] @ hs)
  in
  go [] [ h ]

(* The bug under test: this merge is not heap-correct. *)
let rec merge_heaps left right =
  match (left, right) with
  | None, _ -> right
  | _, None -> left
  | Some (Heap (ln, ll, lr)), Some (Heap (rn, rl, rr)) ->
    if ln <= rn then Some (Heap (ln, merge_heaps lr right, ll))
    else Some (Heap (rn, merge_heaps rr left, rl))

let wrong_to_sorted_list (Heap (n, l, r)) =
  n :: (match merge_heaps l r with Some h -> heap_to_list h | None -> [])

let binheap () =
  bench ~name:"binheap"
    ~gen:(heap_gen 4)
    ~test:(fun h ->
      let l1 = heap_to_list h in
      let l2 = wrong_to_sorted_list h in
      List.equal Int.equal l2 (List.sort l2 ~compare:Int.compare)
      && List.equal Int.equal (List.sort l1 ~compare:Int.compare) l2)
    ~render:render_heap
      (* NOT the upstream string, and the deviation is the finding.
         Upstream states the smallest as
           (0, None, (0, (0, None, None), (1, None, None)))
         but only jqwik and Americium reach it. Measured here, current
         Hypothesis 6.164.0 returns (0, None, (-1, None, None)) on
         100/100 runs -- one distinct answer, mean 25.8 evaluations.
         CsCheck and elm-test land in the same place. Those heaps have
         FEWER nodes but contain a negative, so "smallest" is a
         tie-break between structure size and value magnitude rather
         than an agreed minimum, and scoring against the upstream
         string measures agreement with jqwik, not minimality.

         So the target is what the reference implementation actually
         converges on. That also makes the interesting axis visible:
         Hypothesis gives ONE answer every time; this engine gave 12
         distinct answers in 20 runs. *)
    ~expected:"(0, None, (-1, None, None))" ()

(* ---- difference: three variants, all needing a dependency between
       two separately-drawn integers to be maintained ---- *)
let difference ~name ~bad ~expected =
  bench ~name
    ~gen:(G.both (G.int_uniform_inclusive 0 1_000_000) (G.int_uniform_inclusive 0 1_000_000))
    ~test:(fun (a, b) -> a < 10 || not (bad (abs (a - b))))
    ~render:(fun (a, b) -> Printf.sprintf "[%d, %d]" a b)
    ~expected ()


(* ---- calculator: an expression tree that divides by something which
       EVALUATES to zero without being a literal zero ----

   From the challenge, originally SmartCheck (Pike 2014). The [assume]
   is what makes it interesting: div_subterms rejects any expression
   whose divisor is a *literal* 0, so the only way to fail is a divisor
   that evaluates to 0 by other means. Hence the expected answer, whose
   divisor is ('+', 0, 0). *)
type expr =
  | Lit of int
  | Add of expr * expr
  | Div of expr * expr

let rec render_expr = function
  | Lit n -> Int.to_string n
  | Add (a, b) -> Printf.sprintf "('+', %s, %s)" (render_expr a) (render_expr b)
  | Div (a, b) -> Printf.sprintf "('/', %s, %s)" (render_expr a) (render_expr b)

let rec div_subterms = function
  | Lit _ -> true
  | Div (_, Lit 0) -> false
  | Add (a, b) | Div (a, b) -> div_subterms a && div_subterms b

let rec evaluate = function
  | Lit n -> n
  | Add (a, b) -> evaluate a + evaluate b
  | Div (a, b) -> evaluate a / evaluate b

(* ~size:8 below, not the suite default of 30. [recursive_union] here has
   two recursive branches out of three, so node count grows exponentially
   in size: measured (diag2/probe_calcgen.ml) mean 37 nodes at size 8,
   1357 at size 20, and at 30 the tapes are large enough that a 100-run
   sweep sat for half an hour producing nothing. Hypothesis's st.deferred
   has no size knob and is bounded by their buffer limit instead, which
   is the more robust arrangement for a recursive generator. *)
let expr_gen =
  G.recursive_union
    [ G.map G.int ~f:(fun n -> Lit n) ]
    ~f:(fun self ->
      [ G.map (G.both self self) ~f:(fun (a, b) -> Add (a, b))
      ; G.map (G.both self self) ~f:(fun (a, b) -> Div (a, b))
      ])

let calculator () =
  bench ~name:"calculator" ~gen:expr_gen
    ~test:(fun e ->
      if not (div_subterms e) then raise Tape_stats.Invalid_example;
      match evaluate e with
      | (_ : int) -> true
      | exception Division_by_zero -> false)
    ~render:render_expr ~expected:"('/', 0, ('+', 0, 0))" ~size:8 ~count:20_000 ()

(* ---- bound5: five bounded int16 lists whose WRAPPED sum overflows ----

   The subtlety is that the filter sums as unbounded integers while the
   property sums as int16, so the failure needs wraparound. Their
   expected answer ([], [], [], [-1], [-32768]) is exactly that:
   -1 + -32768 wraps to 32767, which exceeds 5 * 256. *)
let wrap16 x = ((x + 32768) land 0xFFFF) - 32768

let bounded_list =
  (* [int_inclusive] rather than [int_uniform_inclusive] deliberately:
     Hypothesis's from_dtype biases towards the extremes, and reaching
     -32768 is the point of the challenge. *)
  (* st.lists(int16s, max_size=1) is exactly "empty or one element";
     base_quickcheck has no max_length on [list], and spelling it as a
     union also puts [] first, which is the intended minimum. *)
  G.filter
    (G.union
       [ G.return []
       ; G.map (G.int_inclusive (-32768) 32767) ~f:(fun x -> [ x ])
       ])
    ~f:(fun l -> List.sum (module Int) l ~f:Fn.id < 256)

let bound5 () =
  bench ~name:"bound5"
    ~gen:
      (G.map
         (G.both (G.both bounded_list bounded_list)
            (G.both bounded_list (G.both bounded_list bounded_list)))
         ~f:(fun ((a, b), (c, (d, e))) -> [ a; b; c; d; e ]))
    ~test:(fun ls ->
      let total =
        List.fold ls ~init:0 ~f:(fun acc l ->
          List.fold l ~init:acc ~f:(fun acc x -> wrap16 (acc + x)))
      in
      total < 5 * 256)
    ~render:(fun ls ->
      "(" ^ String.concat ~sep:", " (List.map ls ~f:string_of_int_list) ^ ")")
    ~expected:"([], [], [], [-1], [-32768])" ~size:10 ~count:200_000 ()

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
    ; calculator ()
    ; bound5 ()
    ; deletion ()
    ; nestedlists ()
    ; coupling ()
    ; binheap ()
    ]
  in
  Stdio.printf "## Summary\n\n";
  Stdio.printf "| challenge | normalised | 95%% CI | mean evaluations |\n";
  Stdio.printf "|---|---|---|---|\n";
  List.iter results ~f:(fun (name, hits, n, mean) ->
    let lo_ci, hi_ci = wilson ~hits ~n in
    Stdio.printf "| %s | %d/%d | %.1f-%.1f | %.1f |\n" name hits n lo_ci hi_ci mean)

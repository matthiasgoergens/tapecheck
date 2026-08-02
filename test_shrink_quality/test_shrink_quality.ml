(* Port of the portable half of Hypothesis's
   tests/quality/test_shrink_quality.py.

   These are EXACT-minimum assertions: not "did it shrink well" but
   "is the answer precisely this value". That is the kind of assertion
   the guard suite was thinnest on -- regression_guard measures rates
   and costs, which cannot distinguish "usually lands on the minimum"
   from "lands one step away every time".

   Hypothesis's [minimal(strategy)] with no predicate means "every value
   is interesting", i.e. shrink from the first case; here that is simply
   a property that always fails. [minimal(strategy, pred)] becomes a
   property that fails iff [pred] holds.

   NOT ported, and why, so the gaps are visible rather than quietly
   absent: everything needing strategies base_quickcheck does not have
   in the same shape -- fractions, sets, frozensets, dictionaries,
   sampled_from, one_of over mixed types -- and
   test_minimize_single_element_in_silly_large_int_range, whose range is
   [-2^256, 2^256] and cannot be expressed with OCaml's native int at
   all. *)
open! Base
module G = Base_quickcheck.Generator

let checks = ref 0
let passed = ref 0
let gaps = ref []

(* Shrink [gen] under "fails iff [fails]" and hand the minimal value to
   [check]. [show] only runs on a gap, so a costly printer costs nothing
   on the common path. *)
let case ?(size = 30) ~name ~gen ~fails ~check ~show () =
  Int.incr checks;
  match
    Tape_engine.run gen ~test:(fun v -> not (fails v)) ~seed:0 ~count:5_000
      ~size ~budget:20_000 ~max_shrinks:5_000 ~max_stall:(Some 5_000)
  with
  | Tape_engine.Passed _ ->
    gaps := (name, "never found a failing case") :: !gaps;
    Stdio.printf "  gap  %-52s never found a failing case\n" name
  | Tape_engine.Failed { minimal; _ } ->
    if check minimal then begin
      Int.incr passed;
      Stdio.printf "  ok   %-52s %s\n" name (show minimal)
    end
    else begin
      gaps := (name, show minimal) :: !gaps;
      Stdio.printf "  gap  %-52s got %s\n" name (show minimal)
    end

let show_int i = Int.to_string i
let show_ints l = "[" ^ String.concat ~sep:";" (List.map l ~f:Int.to_string) ^ "]"
let show_bools l =
  "[" ^ String.concat ~sep:";" (List.map l ~f:Bool.to_string) ^ "]"

let show_strings l =
  Printf.sprintf "%d strings, total %d chars" (List.length l)
    (List.sum (module Int) l ~f:String.length)

let () =
  Stdio.printf
    "exact-minimum assertions (Hypothesis tests/quality/test_shrink_quality.py)\n\n";

  (* minimal(integers(min_value=101)) == 101 *)
  case ~name:"integers from 101 minimize leftwards"
    ~gen:(G.int_uniform_inclusive 101 100_000)
    ~fails:(fun _ -> true)
    ~check:(fun v -> v = 101) ~show:show_int ();

  (* minimal(integers(-10, 10)) == 0 *)
  case ~name:"bounded integers minimize to zero"
    ~gen:(G.int_uniform_inclusive (-10) 10)
    ~fails:(fun _ -> true)
    ~check:(fun v -> v = 0) ~show:show_int ();

  (* minimal(integers(-10, 10).filter(not_zero)) == 1 -- the shrink
     target itself is excluded, so the answer is the nearest value on
     the positive side rather than -1. *)
  case ~name:"bounded integers, zero filtered out, minimize to 1"
    ~gen:(G.filter (G.int_uniform_inclusive (-10) 10) ~f:(fun v -> v <> 0))
    ~fails:(fun _ -> true)
    ~check:(fun v -> v = 1) ~show:show_int ();

  (* minimal(lists(booleans()), len >= 70) == [False] * 70 *)
  case ~name:"long bool list shrinks to exactly 70 falses"
    ~gen:(G.list G.bool)
    ~fails:(fun l -> List.length l >= 70)
    ~check:(fun l ->
      List.length l = 70 && List.for_all l ~f:(fun b -> not b))
    ~show:(fun l ->
      Printf.sprintf "len %d, %d true" (List.length l)
        (List.count l ~f:Fn.id))
    (* A list generator cannot exceed ~size, so len >= 70 is
       unreachable at the default 30 -- it reported "never found a
       failing case", which reads as a shrink gap and is not one. *)
    ~size:150 ();

  (* minimal(lists(text()), len >= 10) == [""] * 10 *)
  case ~name:"list of strings shrinks to 10 empty strings"
    ~gen:(G.list G.string)
    ~fails:(fun l -> List.length l >= 10)
    ~check:(fun l ->
      List.length l = 10 && List.for_all l ~f:String.is_empty)
    ~show:show_strings ();

  (* minimal(lists(integers()), len(set(x)) < len(x)) has length 2:
     the shortest list containing a duplicate. *)
  case ~name:"shortest list with a duplicate has length 2"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~fails:(fun l ->
      let n = List.length l in
      n > List.length (List.dedup_and_sort l ~compare:Int.compare))
    ~check:(fun l -> List.length l = 2)
    ~show:show_ints ();

  (* test_reordering_bytes: sum >= 10 and len >= 3, and the answer must
     come out SORTED. This one is a direct probe of reorder_spans, which
     this engine does not have -- sort_siblings exists but is off by
     default (SORT-SIBLINGS.md). Recorded, not required. *)
  case ~name:"reordering: sum>=10, len>=3, answer sorted"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~fails:(fun l -> List.sum (module Int) l ~f:Fn.id >= 10 && List.length l >= 3)
    ~check:(fun l ->
      List.equal Int.equal l (List.sort l ~compare:Int.compare))
    ~show:show_ints ();

  (* minimal(lists(lists(booleans())), at least 5 inner lists that are
     non-trivial) == five copies of [False; True]. *)
  case ~name:"nested bool lists: five copies of [false;true]"
    ~gen:(G.list (G.list G.bool))
    ~fails:(fun x ->
      List.length
        (List.filter x ~f:(fun t ->
           List.exists t ~f:Fn.id && List.length t >= 2))
      >= 5)
    ~check:(fun xs ->
      List.length xs = 5
      && List.for_all xs ~f:(fun x -> List.equal Bool.equal x [ false; true ]))
    ~show:(fun xs ->
      Printf.sprintf "%d inner lists: %s" (List.length xs)
        (String.concat ~sep:" "
           (List.map xs ~f:(fun x -> show_bools x))))
    ();

  Stdio.printf "\n  %d/%d exact minima reached\n" !passed !checks;

  (* A FLOOR, like test_poison's 10/34 and test_poison_lists' 20/48.
     Hypothesis passes all of these; this engine does not, and pinning
     the exact figure means a red build nobody reads. The floor catches
     a regression, and beating the recorded number is reported loudly so
     an improvement is not absorbed silently.

     [checks] is asserted too: a file that stops running its cases would
     otherwise report 0/0 and sail past any floor. *)
  let recorded = 5 in
  let expected_checks = 8 in
  let floor = 4 in
  let ok = ref true in
  if !checks <> expected_checks then begin
    ok := false;
    Stdio.printf "  FAIL  ran %d checks, expected %d -- cases stopped running\n"
      !checks expected_checks
  end;
  if !passed < floor then begin
    ok := false;
    Stdio.printf "  FAIL  %d < floor %d (recorded %d, Hypothesis 8/8)\n" !passed
      floor recorded
  end
  else if !passed > recorded then
    Stdio.printf
      "  ****  IMPROVED: %d > the recorded %d. Raise both numbers here.\n"
      !passed recorded
  else
    Stdio.printf "  ok    %d/%d (floor %d, Hypothesis 8/8)\n" !passed !checks
      floor;
  (* The three that remain are all the same family -- a length or a
     structure that will not come down -- which is what LENGTH-REPAIR.md
     is about. Listed rather than summarised so a change in WHICH ones
     fail is visible, not just a change in the count. *)
  if not (List.is_empty !gaps) then begin
    Stdio.printf "\n  outstanding:\n";
    List.iter (List.rev !gaps) ~f:(fun (n, got) ->
      Stdio.printf "    - %-50s %s\n" n got)
  end;
  Stdio.printf "\n";
  if not !ok then Stdlib.exit 1

(* Milestone 5: shrink-quality comparison, stock Shrinker.t vs the
   tape engine, same generators, same failing examples (identical seed
   schedule), greedy first-improvement stock shrinking exactly as
   Base_quickcheck.Test.run does it. *)

open! Base
open Base_quickcheck.Export
open Stdio
module G = Base_quickcheck.Generator
module S = Base_quickcheck.Shrinker

let trials = 100
let stock_budget = 5000
let tape_budget = 5000
let size = 10
let cases_per_trial = 200

let observations =
  match Array.to_list (Sys.get_argv ()) with
  | [ _ ] -> false
  | [ _; "--observations" ] -> true
  | _ -> failwith "usage: shrink_table.exe [--observations]"

let print_observation ~property ~seed ~arm ~found ~minimal ~calls ~result =
  printf "%s\t%d\t%s\t%b\t%b\t%d\t%s\n" property seed arm found minimal calls
    (String.escaped result)

(* Greedy first-improvement loop over Shrinker candidates, the same
   strategy as Base_quickcheck.Test.run, bounded by a test-call
   budget. *)
let stock_shrink shrinker v0 ~test =
  let calls = ref 0 in
  let v = ref v0 in
  let progress = ref true in
  while !progress && !calls < stock_budget do
    progress := false;
    let seq = ref (S.shrink shrinker !v) in
    let scanning = ref true in
    while !scanning && !calls < stock_budget do
      match Sequence.next !seq with
      | None -> scanning := false
      | Some (candidate, rest) ->
        seq := rest;
        Int.incr calls;
        if not (test candidate) then begin
          v := candidate;
          scanning := false;
          progress := true
        end
    done
  done;
  (!v, !calls)

(* An untaped generation schedule. It is NOT what the tape engine does
   any more, and this used to claim otherwise.

   When this file was written the engine generated exactly like this, so
   running the schedule twice gave both arms the same original. Since
   then the engine gained edge-case-biased generation and the
   correlated-value mutation, and the two schedules diverged completely:
   measured (diag2/probe_identical.ml) 100 differing originals out of
   100, on every property, zero overlap. The table was silently
   comparing "stock shrinking a uniformly-sampled failure" against "tape
   shrinking an edge-biased failure", which conflates generation with
   reduction -- exactly the thing it exists to separate.

   [row] below no longer uses this. It takes the ORIGINAL the tape
   engine actually found and hands that same value to the stock
   shrinker, so the comparison is controlled. Kept only for
   [probe_identical] to keep measuring the divergence. *)
let _find_failure_untaped gen ~test ~seed =
  let rec go case =
    if case >= cases_per_trial then None
    else begin
      let random = Splittable_random.of_int (seed + case) in
      let v = G.generate gen ~size ~random in
      if test v then go (case + 1) else Some v
    end
  in
  go 0

type arm_stats =
  { mutable found : int
  ; mutable minimal : int
  ; mutable calls : int
  ; mutable worst : string option
  }

let new_stats () = { found = 0; minimal = 0; calls = 0; worst = None }

let note stats ~is_minimal ~calls ~shown =
  stats.found <- stats.found + 1;
  stats.calls <- stats.calls + calls;
  if is_minimal then stats.minimal <- stats.minimal + 1
  else
    match stats.worst with
    | Some w when String.length w >= String.length shown -> ()
    | _ -> stats.worst <- Some shown

let print_stats name stats =
  printf "  %-9s found %3d/%d, fully minimal %3d/%d, avg %5d test calls, worst: %s\n"
    name stats.found trials stats.minimal trials
    (if stats.found > 0 then stats.calls / stats.found else 0)
    (Option.value stats.worst ~default:"-")

let row (type a) ~id ~name ~(gen : a G.t) ~(shrinker : a S.t option)
    ~(test : a -> bool) ~(is_minimal : a -> bool)
    ~(sexp_of : a -> Sexp.t) =
  if not observations then printf "%s -- %d seeds\n" name trials;
  let stock = new_stats () and tape = new_stats () in
  for trial = 0 to trials - 1 do
    let seed = trial * 1_000_003 in
    (* One generation phase, one original, both arms reduce it. The
       tape engine finds the failure; [original] is the value it found,
       before any shrinking, and that exact value is what the stock
       shrinker is given. Anything else compares generators as well as
       reducers. *)
    match
      Tape_engine.run gen ~test ~seed ~count:cases_per_trial ~size
        ~budget:tape_budget
    with
    | Tape_engine.Passed _ ->
      if observations then begin
        print_observation ~property:id ~seed ~arm:"stock" ~found:false
          ~minimal:false ~calls:0 ~result:"-";
        print_observation ~property:id ~seed ~arm:"tape" ~found:false
          ~minimal:false ~calls:0 ~result:"-"
      end
    | Tape_engine.Failed { minimal; attempts; original; _ } ->
      let stock_minimal, stock_calls =
        match shrinker with
        | Some s -> stock_shrink s original ~test
        | None -> (original, 0)
      in
      note stock ~is_minimal:(is_minimal stock_minimal) ~calls:stock_calls
        ~shown:(Sexp.to_string (sexp_of stock_minimal));
      note tape ~is_minimal:(is_minimal minimal) ~calls:attempts
        ~shown:(Sexp.to_string (sexp_of minimal));
      if observations then begin
        print_observation ~property:id ~seed ~arm:"stock" ~found:true
          ~minimal:(is_minimal stock_minimal) ~calls:stock_calls
          ~result:(Sexp.to_string (sexp_of stock_minimal));
        print_observation ~property:id ~seed ~arm:"tape" ~found:true
          ~minimal:(is_minimal minimal) ~calls:attempts
          ~result:(Sexp.to_string (sexp_of minimal))
      end
  done;
  if not observations then begin
    print_stats "stock" stock;
    print_stats "tape" tape;
    printf "\n"
  end

let () =
  if observations then
    printf "property\tseed\tarm\tfound\tfully_minimal\tshrink_calls\tresult\n";
  row ~id:"integer_threshold"
    ~name:"int uniform in [0, 1_000_000], fail iff v >= 123_457"
    ~gen:(G.int_uniform_inclusive 0 1_000_000)
    ~shrinker:(Some S.int)
    ~test:(fun v -> v < 123_457)
    ~is_minimal:(fun v -> v = 123_457)
    ~sexp_of:[%sexp_of: int];

  row ~id:"pair_sum" ~name:"pair in [0,1000]^2, fail iff a + b >= 100"
    ~gen:(G.both (G.int_uniform_inclusive 0 1000) (G.int_uniform_inclusive 0 1000))
    ~shrinker:(Some [%quickcheck.shrinker: int * int])
    ~test:(fun (a, b) -> a + b < 100)
    ~is_minimal:(fun (a, b) -> a = 0 && b = 100)
    ~sexp_of:[%sexp_of: int * int];

  row ~id:"list_length" ~name:"int list, fail iff length >= 3"
    ~gen:(G.list (G.int_uniform_inclusive 0 100))
    ~shrinker:(Some (S.list S.int))
    ~test:(fun l -> List.length l < 3)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 0; 0; 0 ])
    ~sexp_of:[%sexp_of: int list];

  row ~id:"list_sum" ~name:"int list, fail iff sum >= 100"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~shrinker:(Some (S.list S.int))
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ])
    ~sexp_of:[%sexp_of: int list];

  row ~id:"filtered_even" ~name:"filtered even ints, fail iff v >= 100"
    ~gen:(G.filter (G.int_uniform_inclusive 0 100_000) ~f:(fun v -> v % 2 = 0))
    ~shrinker:(Some S.int)
    ~test:(fun v -> v < 100)
    ~is_minimal:(fun v -> v = 100)
    ~sexp_of:[%sexp_of: int];

  (* THE ZIG-ZAG TRAP, ported from Hypothesis's
     tests/quality/test_zig_zagging.py::test_avoids_zig_zag_trap. Two
     values must stay exactly 1 apart to keep failing, so lowering
     either ALONE always succeeds by one step and never more: a naive
     shrinker walks m and n down in lockstep, O(m) attempts instead of
     O(log m). Hypothesis considers this important enough to assert a
     quantitative bound on it,
       budget = 2 * n_bits * ceil(log2 n_bits) + 2
     which for 20-bit values is ~2*20*5 + 2 = 202. It is the only
     shrink-COST test in their quality suite, and cost is precisely what
     tapecheck's own suite was missing. *)
  row ~id:"zig_zag"
    ~name:"zig-zag: fails iff |m - n| = 1   [hypothesis asserts a cost bound]"
    ~gen:
      (G.both (G.int_uniform_inclusive 0 300)
         (G.int_uniform_inclusive 0 300))
    ~shrinker:(Some [%quickcheck.shrinker: int * int])
    ~test:(fun (m, n) -> abs (m - n) <> 1)
    ~is_minimal:(fun (m, n) -> (m = 0 && n = 1) || (m = 1 && n = 0))
    ~sexp_of:[%sexp_of: int * int];

  (* Long-range dependency, from harder_benchmarks.py in the companion
     evidence archive pinned by EVIDENCE.md. Deleting an element breaks
     [hd l = length l], and lowering [hd l] breaks it too, so only a
     SIMULTANEOUS lower-and-delete makes progress -- precisely what
     lower_and_delete exists for and what Hypothesis has no single pass
     for. Measured Hypothesis: found 89/100, fully minimal 53/100, worst
     [8;0;0;0;0;0;0;0] against a true minimum of [1]. *)
  row ~id:"self_length"
    ~name:"self_len: fails iff l <> [] && hd l = length l   [hypothesis: 53/100]"
    ~gen:(G.list (G.int_uniform_inclusive 0 50))
    ~shrinker:(Some (S.list S.int))
    ~test:(fun l ->
      not (match l with [] -> false | h :: _ -> h = List.length l))
    ~is_minimal:(fun l -> List.equal Int.equal l [ 1 ])
    ~sexp_of:[%sexp_of: int list];

  row ~id:"length_prefixed_bind"
    ~name:"bind: len in [1,64], list_with_length, fail iff sum >= 100 (no stock shrinker derivable)"
    ~gen:
      (let open G.Let_syntax in
       let%bind len = G.int_uniform_inclusive 1 64 in
       G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
    ~shrinker:None
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ])
    ~sexp_of:[%sexp_of: int list]

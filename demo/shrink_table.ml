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

(* The same untaped generation schedule the tape engine uses, so both
   arms shrink the identical original failing example. *)
let find_failure gen ~test ~seed =
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

let row (type a) ~name ~(gen : a G.t) ~(shrinker : a S.t option)
    ~(test : a -> bool) ~(is_minimal : a -> bool)
    ~(sexp_of : a -> Sexp.t) =
  printf "%s -- %d seeds\n" name trials;
  let stock = new_stats () and tape = new_stats () in
  for trial = 0 to trials - 1 do
    let seed = trial * 1_000_003 in
    (* Stock arm. *)
    (match find_failure gen ~test ~seed with
    | None -> ()
    | Some original ->
      let minimal, calls =
        match shrinker with
        | Some s -> stock_shrink s original ~test
        | None -> (original, 0)
      in
      note stock ~is_minimal:(is_minimal minimal) ~calls
        ~shown:(Sexp.to_string (sexp_of minimal)));
    (* Tape arm. *)
    match
      Tape_engine.run gen ~test ~seed ~count:cases_per_trial ~size
        ~budget:tape_budget
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal; attempts; _ } ->
      note tape ~is_minimal:(is_minimal minimal) ~calls:attempts
        ~shown:(Sexp.to_string (sexp_of minimal))
  done;
  print_stats "stock" stock;
  print_stats "tape" tape;
  printf "\n"

let () =
  row ~name:"int uniform in [0, 1_000_000], fail iff v >= 123_457"
    ~gen:(G.int_uniform_inclusive 0 1_000_000)
    ~shrinker:(Some S.int)
    ~test:(fun v -> v < 123_457)
    ~is_minimal:(fun v -> v = 123_457)
    ~sexp_of:[%sexp_of: int];

  row ~name:"pair in [0,1000]^2, fail iff a + b >= 100"
    ~gen:(G.both (G.int_uniform_inclusive 0 1000) (G.int_uniform_inclusive 0 1000))
    ~shrinker:(Some [%quickcheck.shrinker: int * int])
    ~test:(fun (a, b) -> a + b < 100)
    ~is_minimal:(fun (a, b) -> a = 0 && b = 100)
    ~sexp_of:[%sexp_of: int * int];

  row ~name:"int list, fail iff length >= 3"
    ~gen:(G.list (G.int_uniform_inclusive 0 100))
    ~shrinker:(Some (S.list S.int))
    ~test:(fun l -> List.length l < 3)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 0; 0; 0 ])
    ~sexp_of:[%sexp_of: int list];

  row ~name:"int list, fail iff sum >= 100"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~shrinker:(Some (S.list S.int))
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ])
    ~sexp_of:[%sexp_of: int list];

  row ~name:"filtered even ints, fail iff v >= 100"
    ~gen:(G.filter (G.int_uniform_inclusive 0 100_000) ~f:(fun v -> v % 2 = 0))
    ~shrinker:(Some S.int)
    ~test:(fun v -> v < 100)
    ~is_minimal:(fun v -> v = 100)
    ~sexp_of:[%sexp_of: int];

  row ~name:"bind: len in [1,64], list_with_length, fail iff sum >= 100 (no stock shrinker derivable)"
    ~gen:
      (let open G.Let_syntax in
       let%bind len = G.int_uniform_inclusive 1 64 in
       G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
    ~shrinker:None
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
    ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ])
    ~sexp_of:[%sexp_of: int list]

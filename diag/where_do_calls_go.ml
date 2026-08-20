(* Where do tapecheck's 641 shrink calls go on "int list, length >= 3",
   when Hypothesis finishes the same property in 27?
   See the pinned companion Hypothesis baseline in EVIDENCE.md. *)

open Base
module G = Base_quickcheck.Generator

let trials = 500

(* Seed offset from argv, so a replication can use a DISJOINT seed set.
   Comparing t in [0,500) against t in [0,100) is not a replication --
   the smaller set is contained in the larger, so agreement is partly
   guaranteed. Different seeds also matter because generation hits
   different large examples first, which means the shrinker gets
   genuinely different inputs, not just more of the same ones. *)
let seed_offset =
  if Array.length (Stdlib.Sys.argv) > 1 then Int.of_string Stdlib.Sys.argv.(1)
  else 0

let row ~name ~gen ~test =
  let totals = Hashtbl.Poly.create () in
  let dups = ref 0 and distinct = ref 0 and runs = ref 0 and greedy = ref 0 and accs = ref 0
  and sw = ref 0 and ic = ref 0 and fc = ref 0 and iv = ref 0 and jk = ref 0 and nonconv = ref 0 in
  for t = 0 to trials - 1 do
    match Tape_engine.run gen ~test ~seed:((t + seed_offset) * 1_000_003) ~count:200 ~size:10 with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { converged; _ } ->
      Int.incr runs;
      if not converged then Int.incr nonconv;
      List.iter (Tape_engine.Diagnostics.last_pass_costs ()) ~f:(fun (p, c) ->
        Hashtbl.update totals p ~f:(function None -> c | Some x -> x + c));
      let d, dd = Tape_engine.Diagnostics.last_duplicate_stats () in
      dups := !dups + d;
      distinct := !distinct + dd;
      greedy := !greedy + Tape_engine.Diagnostics.last_greedy_cost ();
      let a, b, c, d, e, f = Tape_engine.Diagnostics.last_shape () in
      sw := !sw + a;
      ic := !ic + b;
      fc := !fc + c;
      iv := !iv + d;
      jk := !jk + e;
      accs := !accs + f;
  done;
  Stdio.printf "%s (%d failing runs)\n" name !runs;
  let n = Int.max 1 !runs in
  Hashtbl.to_alist totals
  |> List.sort ~compare:(fun (_, a) (_, b) -> Int.compare b a)
  |> List.iter ~f:(fun (p, c) ->
    Stdio.printf "  %-20s %6d avg attempts\n" p (c / n));
  Stdio.printf "  %-20s %6d avg (of which greedy-repeat loop; rest is the s/i/k/j scan)\n"
    "  ^ lower_and_delete" (!greedy / n);
  Stdio.printf "  %-20s %6d avg accepted shrinks (each restarts the scan at i:=0)\n"
    "  ^ acceptances" (!accs / n);
  Stdio.printf
    "  non-converged: %d/%d\n  shape: %d sweeps, %d -> %d choices, %d i-visits, %d (j,k) visits, %d SUCCESSES in lower_and_delete\n"
    !nonconv !runs (!sw / n) (!ic / n) (!fc / n) (!iv / n) (!jk / n) (!accs / n);
  Stdio.printf "  %-20s %6d avg (%.0f%% of proposals were exact repeats)\n"
    "duplicates" (!dups / n)
    (100. *. Float.of_int !dups /. Float.of_int (Int.max 1 (!dups + !distinct)));
  Stdio.printf "\n"

let () =
  row ~name:"int list, fail iff length >= 3"
    ~gen:(G.list (G.int_uniform_inclusive 0 100))
    ~test:(fun l -> List.length l < 3);
  row ~name:"int list, fail iff sum >= 100"
    ~gen:(G.list (G.int_uniform_inclusive 0 1000))
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100);
  row ~name:"filtered even ints, fail iff v >= 100"
    ~gen:(G.filter (G.int_uniform_inclusive 0 100_000) ~f:(fun v -> v % 2 = 0))
    ~test:(fun v -> v < 100);
  row ~name:"bind: len in [1,64], list_with_length, fail iff sum >= 100"
    ~gen:
      (let open G.Let_syntax in
       let%bind len = G.int_uniform_inclusive 1 64 in
       G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
    ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100);
  row ~name:"pair in [0,1000]^2, fail iff a + b >= 100"
    ~gen:(G.both (G.int_uniform_inclusive 0 1000) (G.int_uniform_inclusive 0 1000))
    ~test:(fun (a, b) -> a + b < 100);
  row ~name:"self_len: fails iff hd l = length l  (FRONTIER: tape 47, hyp 53)"
    ~gen:(G.list (G.int_uniform_inclusive 0 50))
    ~test:(fun l ->
      not (match l with [] -> false | h :: _ -> h = List.length l));
  row ~name:"zig-zag: fails iff |m - n| = 1  (now fixed by lower_together)"
    ~gen:(G.both (G.int_uniform_inclusive 0 300) (G.int_uniform_inclusive 0 300))
    ~test:(fun (m, n) -> abs (m - n) <> 1);
  row ~name:"int uniform (control: tapecheck already cheap here)"
    ~gen:(G.int_uniform_inclusive 0 1_000_000)
    ~test:(fun v -> v < 123_457)

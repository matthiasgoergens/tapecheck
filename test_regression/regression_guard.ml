(* Regression guard for shrink QUALITY and shrink COST.

   Every threshold below was established by measurement during the
   2026-07-31 investigation, and every one names the specific regression
   it exists to catch. If you change the engine and this fails, read the
   named finding before adjusting the number: several of these bounds
   were violated by changes that looked obviously correct.

   Why cost is guarded at all: shrink quality alone is a poor alarm. All
   three bad changes below kept quality at 100/100 while making cost 3x
   to 20x worse, so a quality-only suite would have passed every one of
   them.

   Bounds, not exact equality. Runs are deterministic (fixed seeds), so
   exact values would be reproducible, but then any legitimate
   improvement fails the suite too. Ceilings sit ~40% above measured, so
   noise passes and the real regressions (2.3x-20x) do not. Quality
   floors are >=, so improvements always pass.

   On failure the actual numbers are printed next to the expected ones,
   so drift is visible even when it is under the ceiling.

   VALIDATED against the known-bad changes, not merely observed to pass.
   A guard that has never failed is not evidence of anything:

     - cutoff off              -> 3 FAILs (641 > 250, 456 > 245, 388 > 245)
     - max_stall 200, cutoff off -> 4 FAILs, reproducing the original
       harm exactly: 1/100 and 26/100 fully minimal, plus non-converged
     - max_stall 200, cutoff ON  -> PASSES, and that is correct: the
       cutoff stops a pass long before 200 consecutive failures can
       accumulate, so the stall never fires. The two interact;
       max_stall is inert given the cutoff rather than safe on its own. *)

open Base
module G = Base_quickcheck.Generator

let trials = 100
let cases_per_trial = 200

type expectation =
  { name : string
  ; min_found : int
  ; min_minimal : int
  ; max_avg_calls : int
  ; max_non_converged : int
      (* Normally 0: the per-pass cutoff must not clear [converged].
         Non-zero only for a recorded FRONTIER, where a property is
         known not to settle and the number is what it currently is. *)
  ; catches : string
  }

type outcome =
  { found : int
  ; minimal : int
  ; avg_calls : int
  ; non_converged : int
  }

(* [size] is a parameter because one property is specifically about
   LONG tapes: the per-pass cutoff is now proportional to tape length,
   and at the default size:10 the lengthlist tapes are too short for the
   proportional term to matter, so the guard would barely register a
   revert to a flat cutoff. Everything else keeps the original 10. *)
let measure (type a) ?(size = 10) ~(gen : a G.t) ~(test : a -> bool)
      ~(is_minimal : a -> bool) () : outcome =
  let found = ref 0 and minimal = ref 0 and calls = ref 0 in
  let non_converged = ref 0 in
  for t = 0 to trials - 1 do
    match
      Tape_engine.run gen ~test ~seed:(t * 1_000_003) ~count:cases_per_trial
        ~size
    with
    | Tape_engine.Passed _ -> ()
    | Tape_engine.Failed { minimal = m; attempts; converged; _ } ->
      Int.incr found;
      calls := !calls + attempts;
      if is_minimal m then Int.incr minimal;
      if not converged then Int.incr non_converged
  done;
  { found = !found
  ; minimal = !minimal
  ; avg_calls = !calls / trials
  ; non_converged = !non_converged
  }

let failures = ref 0

let check (e : expectation) (o : outcome) =
  let problems = ref [] in
  if o.found < e.min_found then
    problems := Printf.sprintf "found %d < %d" o.found e.min_found :: !problems;
  if o.minimal < e.min_minimal then
    problems :=
      Printf.sprintf "fully minimal %d < %d" o.minimal e.min_minimal
      :: !problems;
  if o.avg_calls > e.max_avg_calls then
    problems :=
      Printf.sprintf "avg calls %d > %d" o.avg_calls e.max_avg_calls
      :: !problems;
  (* The per-pass failure cutoff must not clear [converged]: it means
     "the search settled", and more budget cannot change a cutoff that is
     not budget-driven. An engine change that makes runs report
     not-converged is either a real budget problem or a reintroduction of
     the verification-sweep confusion. *)
  if o.non_converged > e.max_non_converged then
    problems :=
      Printf.sprintf "non-converged %d/%d (allowed %d)" o.non_converged trials
        e.max_non_converged
      :: !problems;
  match !problems with
  | [] ->
    Stdio.printf "  ok   %-52s found %3d, minimal %3d, %4d calls\n" e.name
      o.found o.minimal o.avg_calls
  | ps ->
    Int.incr failures;
    Stdio.printf "  FAIL %-52s %s\n" e.name (String.concat ~sep:"; " ps);
    Stdio.printf "       guards against: %s\n" e.catches

(* --- the properties, with their measured baselines --------------------- *)

let bug_ref =
  "see ../tapecheck-hypothesis-baseline/README.md and BENCHMARKS.md"

let () =
  Stdio.printf "shrink quality and cost regression guard (%d seeds each)\n"
    trials;
  Stdio.printf "baselines measured 2026-07-31; %s\n\n" bug_ref;

  check
    { name = "int uniform, fail iff v >= 123_457"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 50 (* measured 34 after duplicate-skipping *)
    ; max_non_converged = 0
    ; catches =
        "scalar shrinking via minimize_choices' binary search; if this \
         regresses to linear descent the cost explodes"
    }
    (measure
       ~gen:(G.int_uniform_inclusive 0 1_000_000)
       ~test:(fun v -> v < 123_457)
       ~is_minimal:(fun v -> v = 123_457) ());

  check
    { name = "pair, fail iff a + b >= 100"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 26 (* measured 18 after duplicate-skipping *)
    ; max_non_converged = 0
    ; catches = "multi-choice coordination on the cheapest possible case"
    }
    (measure
       ~gen:(G.both (G.int_uniform_inclusive 0 1000)
               (G.int_uniform_inclusive 0 1000))
       ~test:(fun (a, b) -> a + b < 100)
       ~is_minimal:(fun (a, b) -> a = 0 && b = 100) ());

  check
    { name = "int list, fail iff length >= 3"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 205 (* measured 147; 178 before duplicate-skipping, 641 before the cutoff *)
    ; max_non_converged = 0
    ; catches =
        "REMOVING the per-pass failure cutoff (?max_pass_failures). \
         lower_and_delete scores ZERO successes here while spending 96% \
         of the shrink; without the cutoff this returns to 641. Also \
         catches re-adding uncut verification sweeps, which cost 2x."
    }
    (measure
       ~gen:(G.list (G.int_uniform_inclusive 0 100))
       ~test:(fun l -> List.length l < 3)
       ~is_minimal:(fun l -> List.equal Int.equal l [ 0; 0; 0 ]) ());

  check
    { name = "int list, fail iff sum >= 100"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 130 (* measured 90; 173 before duplicate-skipping, 456 before the cutoff *)
    ; max_non_converged = 0
    ; catches =
        "as above; also the max_stall port, which took this property to \
         26/100 fully minimal by cutting passes off before they ran"
    }
    (measure
       ~gen:(G.list (G.int_uniform_inclusive 0 1000))
       ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
       ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ]) ());

  check
    { name = "filtered even ints, fail iff v >= 100"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 112 (* measured 79 after duplicate-skipping *)
    ; max_non_converged = 0
    ; catches =
        "filtered-generator overhead. Rejected draws stay on the tape and \
         get minimised: 90 here vs 37 for the same shape unfiltered. If \
         discard marking lands this should DROP; if it rises, the filter \
         path regressed."
    }
    (measure
       ~gen:(G.filter (G.int_uniform_inclusive 0 100_000) ~f:(fun v -> v % 2 = 0))
       ~test:(fun v -> v < 100)
       ~is_minimal:(fun v -> v = 100) ());

  check
    { name = "bind, fail iff sum >= 100 (no stock shrinker)"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 74 (* measured 52 after duplicate-skipping *)
    ; max_non_converged = 0
    ; catches =
        "THE GALLOPING DESCENT REGRESSION. bind is the only \
         greedy-dominated property (30 of 40 attempts). Replacing \
         lower_and_delete's +/-1 step with a halving gallop took this to \
         984 calls, because when only small steps are accepted each one \
         costs ~log(range) failures. Patch kept at \
         galloping-attempt-REJECTED.patch."
    }
    (measure
       ~gen:
         (let open G.Let_syntax in
          let%bind len = G.int_uniform_inclusive 1 64 in
          G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
       ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
       ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ]) ());

  (* Ported from Hypothesis tests/quality/test_zig_zagging.py. Two
     values must stay exactly 1 apart, so lowering either alone works by
     one step and never more. Without lower_together this cost 2929
     calls and reached the true minimum only 51/100, because the
     lockstep descent exhausted the budget; with it, 37 calls and every
     found case minimal. Guards the zig-zag defence specifically. *)
  check
    { name = "zig-zag, fails iff |m - n| = 1"
    ; min_found = 75
    ; min_minimal = 75 (* measured 83 of 83 found *)
    ; max_avg_calls = 44 (* measured 28; 2929 without lower_together *)
    ; max_non_converged = 0
    ; catches =
        "removing or breaking lower_together, the port of Hypothesis's          lower_blocks_together. Also catches reverting find_integer to a          halve-from-the-top gallop: the linear scan over 1..4 first is          what stops small steps costing log(range) failures each."
    }
    (measure
       ~gen:(G.both (G.int_uniform_inclusive 0 300)
               (G.int_uniform_inclusive 0 300))
       ~test:(fun (m, n) -> abs (m - n) <> 1)
       ~is_minimal:(fun (m, n) -> (m = 0 && n = 1) || (m = 1 && n = 0)) ());

  (* Guards the per-pass cutoff CONSTANT, not just its presence. With
     max_pass_failures at 20 this matches no-cutoff exactly (100/100);
     at 3 it collapses to 47/100 (diag2/probe_cutoff.ml). Adaptation
     cannot rescue a too-small value -- growth only fires after a
     success, and a too-small budget never gets one -- so the constant
     itself has to be defended. Do not lower 20. *)
  check
    { name = "deep bind, len in [1,200], sum >= 500"
    ; min_found = 95
    ; min_minimal = 95 (* measured 100; 47 with the cutoff at 3 *)
    ; max_avg_calls = 210 (* measured 149; 250 with no cutoff at all *)
    ; max_non_converged = 0
    ; catches =
        "lowering max_pass_failures below 20. Measured: 20 matches \
         no-cutoff exactly, 3 gives 47/100 fully minimal. The seven other \
         properties all succeed well inside 20 and cannot detect this."
    }
    (measure
       ~gen:
         (let open G.Let_syntax in
          let%bind len = G.int_uniform_inclusive 1 200 in
          G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:len)
       ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 500)
       ~is_minimal:(fun l -> List.equal Int.equal l [ 500 ]) ());

  (* FRONTIER, like self_len below: recorded rather than satisfied.

     This is lengthlist from jlink/shrinking-challenge (CHALLENGE.md).
     It is the same bind-then-fixed-length shape as the property above,
     but with max rather than sum as the predicate, and that changes
     everything: with sum almost any element reduction is productive,
     whereas with max only one element matters and the length reduction
     that isolates it takes many failed attempts to land. Hypothesis
     normalises it 100/100 at 88 evaluations; we do not.

     The cause is known and the obvious fix was tried and reverted. A
     flat per-pass failure cutoff of 20 is a very different fraction of
     this property's tapes than of a short one, and making it
     proportional (max 20 (len/3)) takes this to 100/100 at half the
     cost with the other nine properties untouched. It also breaks
     test_poison's base-tree construction, because the same patience is
     granted to unproductive passes and is paid for out of the global
     budget. No divisor satisfies both -- see the comment on [live] in
     tape_engine.ml. Earned patience, scaled by a pass's own success
     rate, is the real fix and is not done.

     ~size:30 because this property is about LONG tapes; at the default
     size:10 the tapes are too short to exercise the interaction. *)
  check
    { name = "lengthlist: bind len, max >= 900  [frontier: not 100/100]"
    ; min_found = 100
    ; min_minimal = 60 (* measured 70; 100 with a proportional cutoff *)
    ; max_avg_calls = 400 (* measured 279; 147 with a proportional cutoff *)
    ; max_non_converged = 40 (* measured 27; 0 with a proportional cutoff *)
    ; catches =
        "a drop below the recorded 70/100, and equally an unnoticed \
         IMPROVEMENT -- if this reaches 100 the frontier has moved and \
         both this bound and CHALLENGE.md should be updated."
    }
    (measure
       ~gen:
         (G.bind (G.int_uniform_inclusive 1 100) ~f:(fun n ->
            G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:n))
       ~test:(fun l ->
         match List.max_elt l ~compare:Int.compare with
         | None -> true
         | Some m -> m < 900)
       ~is_minimal:(fun l -> List.equal Int.equal l [ 900 ])
       ~size:30 ());

  (* Deliberately NOT at 100/100: this is the open frontier case, where
     both engines are far from optimal (tape 47, Hypothesis 53). The
     floor is set just under the current value so a genuine improvement
     passes and a silent degradation does not. Raise the floor when it
     improves. *)
  check
    { name = "self_len, fails iff hd l = length l  [frontier: not 100/100]"
    ; min_found = 90
    ; min_minimal = 40 (* measured 47; Hypothesis gets 53 *)
    ; max_avg_calls = 180 (* measured 127 after duplicate-skipping *)
    ; max_non_converged = 0
    ; catches =
        "the long-range-dependency frontier. Both engines get trapped on \
         a list of n zeros headed by n. If min_minimal ever exceeds 53 \
         this beats Hypothesis and the number belongs in the email."
    }
    (measure
       ~gen:(G.list (G.int_uniform_inclusive 0 50))
       ~test:(fun l ->
         not (match l with [] -> false | h :: _ -> h = List.length l))
       ~is_minimal:(fun l -> List.equal Int.equal l [ 1 ]) ());

  Stdio.printf "\n";
  if !failures > 0 then begin
    Stdio.printf
      "%d regression(s). Read the named finding before adjusting a bound:\n\
      \  several of these were violated by changes that looked obviously\n\
      \  correct, and quality stayed at 100/100 while cost went 3x-20x.\n"
      !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "all guards passed\n"

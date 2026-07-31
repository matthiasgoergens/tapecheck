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
  ; catches : string
  }

type outcome =
  { found : int
  ; minimal : int
  ; avg_calls : int
  ; non_converged : int
  }

let measure (type a) ~(gen : a G.t) ~(test : a -> bool)
      ~(is_minimal : a -> bool) : outcome =
  let found = ref 0 and minimal = ref 0 and calls = ref 0 in
  let non_converged = ref 0 in
  for t = 0 to trials - 1 do
    match
      Tape_engine.run gen ~test ~seed:(t * 1_000_003) ~count:cases_per_trial
        ~size:10
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
  if o.non_converged > 0 then
    problems :=
      Printf.sprintf "non-converged %d/%d (expected 0)" o.non_converged trials
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
    ; max_avg_calls = 55 (* measured 38 *)
    ; catches =
        "scalar shrinking via minimize_choices' binary search; if this \
         regresses to linear descent the cost explodes"
    }
    (measure
       ~gen:(G.int_uniform_inclusive 0 1_000_000)
       ~test:(fun v -> v < 123_457)
       ~is_minimal:(fun v -> v = 123_457));

  check
    { name = "pair, fail iff a + b >= 100"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 32 (* measured 22 *)
    ; catches = "multi-choice coordination on the cheapest possible case"
    }
    (measure
       ~gen:(G.both (G.int_uniform_inclusive 0 1000)
               (G.int_uniform_inclusive 0 1000))
       ~test:(fun (a, b) -> a + b < 100)
       ~is_minimal:(fun (a, b) -> a = 0 && b = 100));

  check
    { name = "int list, fail iff length >= 3"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 250 (* measured 176, was 641 before the cutoff *)
    ; catches =
        "REMOVING the per-pass failure cutoff (?max_pass_failures). \
         lower_and_delete scores ZERO successes here while spending 96% \
         of the shrink; without the cutoff this returns to 641. Also \
         catches re-adding uncut verification sweeps, which cost 2x."
    }
    (measure
       ~gen:(G.list (G.int_uniform_inclusive 0 100))
       ~test:(fun l -> List.length l < 3)
       ~is_minimal:(fun l -> List.equal Int.equal l [ 0; 0; 0 ]));

  check
    { name = "int list, fail iff sum >= 100"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 245 (* measured 173, was 456 before the cutoff *)
    ; catches =
        "as above; also the max_stall port, which took this property to \
         26/100 fully minimal by cutting passes off before they ran"
    }
    (measure
       ~gen:(G.list (G.int_uniform_inclusive 0 1000))
       ~test:(fun l -> List.sum (module Int) l ~f:Fn.id < 100)
       ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ]));

  check
    { name = "filtered even ints, fail iff v >= 100"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 130 (* measured 90 *)
    ; catches =
        "filtered-generator overhead. Rejected draws stay on the tape and \
         get minimised: 90 here vs 37 for the same shape unfiltered. If \
         discard marking lands this should DROP; if it rises, the filter \
         path regressed."
    }
    (measure
       ~gen:(G.filter (G.int_uniform_inclusive 0 100_000) ~f:(fun v -> v % 2 = 0))
       ~test:(fun v -> v < 100)
       ~is_minimal:(fun v -> v = 100));

  check
    { name = "bind, fail iff sum >= 100 (no stock shrinker)"
    ; min_found = 100
    ; min_minimal = 100
    ; max_avg_calls = 80 (* measured 56 *)
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
       ~is_minimal:(fun l -> List.equal Int.equal l [ 100 ]));

  (* Deliberately NOT at 100/100: this is the open frontier case, where
     both engines are far from optimal (tape 47, Hypothesis 53). The
     floor is set just under the current value so a genuine improvement
     passes and a silent degradation does not. Raise the floor when it
     improves. *)
  check
    { name = "self_len, fails iff hd l = length l  [frontier: not 100/100]"
    ; min_found = 90
    ; min_minimal = 40 (* measured 47; Hypothesis gets 53 *)
    ; max_avg_calls = 245 (* measured 175 *)
    ; catches =
        "the long-range-dependency frontier. Both engines get trapped on \
         a list of n zeros headed by n. If min_minimal ever exceeds 53 \
         this beats Hypothesis and the number belongs in the email."
    }
    (measure
       ~gen:(G.list (G.int_uniform_inclusive 0 50))
       ~test:(fun l ->
         not (match l with [] -> false | h :: _ -> h = List.length l))
       ~is_minimal:(fun l -> List.equal Int.equal l [ 1 ]));

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

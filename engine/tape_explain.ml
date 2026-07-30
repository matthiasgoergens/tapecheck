(* RO5, input half of Hypothesis's Phase.explain (outreach/ro-roadmap.md,
   "RO5 half 2"). After shrinking has converged on a minimal tape image,
   perturb each recorded choice IN ISOLATION -- holding every other
   choice on the tape fixed -- and re-run the generator and test. A
   choice whose value can change without the test starting to pass is
   irrelevant to the failure; a choice for which no such change was
   found is a candidate for being load-bearing.

   This suits the tape model specifically: choices are individually
   addressable and independently replayable, which a rose-tree /
   integrated shrinker (QCheck2, Bam) has no equivalent handle for,
   because its shrink structure is fixed as the value is constructed.
   There is no "choice 7" to perturb in a shrink tree assembled around
   already-committed sub-values; the tape gives every recorded decision
   a stable address that survives the whole run.

   Hypothesis's own stated posture, copied deliberately: "If there are
   no clearly suspicious lines of code, we refuse the temptation to
   guess." Applied here: failing to find a still-failing perturbation
   within budget does NOT prove the choice is load-bearing, only that
   this bounded search did not find one. [No_variation_found] is
   reported as exactly that, never as proof, and [complete] on the
   overall report says plainly when the budget ran out before every
   choice was even given a fair try.

   This module is intentionally a leaf: [Tape_engine] does not know it
   exists, so the "phase" is switched off simply by not calling
   [analyze] (wired as an opt-in ?explain flag in Tape_test). *)

open! Base

type 'a outcome =
  | Varies of { examples : 'a list }
      (* At least one alternative value at this position -- everything
         else on the tape held fixed -- regenerated a value that still
         failed the test. [examples] holds up to
         [max_examples_per_choice] distinct such values, so a human can
         compare them against the minimal example directly rather than
         trust a bare "choice 7" label. *)
  | No_variation_found
      (* Every alternative tried within budget either made the test
         pass, or could not be tried cleanly (it overran or
         desynchronized the tape, so it is not evidence either way).
         A negative result from a BOUNDED search, not a proof of
         necessity. *)
  | No_alternative_possible
      (* The choice's range is a single point (lo = hi): "does it vary"
         is not a meaningful question, so this is kept separate from a
         search that came up empty. *)

type 'a choice_report =
  { seg : int (* 0 = main stream; s >= 1 = image.streams.(s - 1) *)
  ; stream_key : Tape.key
  ; index : int (* position within that stream *)
  ; original : Tape.choice
  ; outcome : 'a outcome
  ; tries : int (* candidates actually executed at this position *)
  }

type 'a t =
  { choices : 'a choice_report list
  ; budget : int
  ; used : int (* candidate replays actually spent, <= budget *)
  ; complete : bool
      (* false if the budget ran out before every choice either
         exhausted its candidate list or found enough examples -- i.e.
         some [No_variation_found] verdicts above are weaker than
         usual, because the search stopped early rather than running
         dry. Check per-choice [tries] for exactly how little (or how
         much) a given verdict rests on. *)
  }

(* Budget: a few hundred replays, the same order of magnitude as ONE
   generation-and-test pass through Tape_engine.run's own search, and
   well under a shrink run's budget (default 2000; the six properties
   in the README results table average 22-466 shrink calls to reach
   the minimal example). This analysis runs once, AFTER shrinking has
   already converged, so every replay it spends is pure overhead on
   top of an already-passing search; 200 keeps that overhead bounded
   regardless of how many choices the minimal tape has, while still
   giving small tapes (a handful of choices, the common case for a
   minimized example) several tries apiece before the budget runs
   out. *)
let default_budget = 200

(* Per-choice caps, independent of the overall budget: stop asking a
   given choice for more evidence once it has enough (3 distinct
   still-failing values is plenty to call it "varies freely" without
   spending the whole budget re-confirming it), and never try more
   than 8 candidates at any one position even if nothing has failed
   yet, so one wide-range choice cannot starve every other choice on
   the tape of its share of the budget. *)
let max_tries_per_choice = 8
let max_examples_per_choice = 3
let extra_random_samples = 4

(* Candidate alternative values for one recorded choice, most
   informative first: the shrink target and the range endpoints (the
   values a reader is most likely to already be comparing against),
   the immediate neighbors of the current value, then a handful of
   deterministic pseudo-random samples spread across the range so a
   choice with a huge span still gets some coverage beyond its edges.
   [seed] is derived from the choice's tape position, so the sample is
   reproducible across runs without needing real entropy. *)
let candidates_for (c : Tape.choice) ~seed : Tape.choice list =
  match c with
  | Tape.Marker -> []
  | Tape.Bool b -> [ Tape.Bool (not b) ]
  | Tape.Integer { value; lo; hi } ->
    if Int64.(lo = hi) then []
    else begin
      let target = Tape.clamp_int64 0L ~lo ~hi in
      let hand =
        List.filter_opt
          [ Some target
          ; Some lo
          ; Some hi
          ; (if Int64.(value > lo) then Some Int64.(value - 1L) else None)
          ; (if Int64.(value < hi) then Some Int64.(value + 1L) else None)
          ]
      in
      let rand = Splittable_random.of_int seed in
      let extra =
        List.init extra_random_samples ~f:(fun _ ->
          Splittable_random.int64 rand ~lo ~hi)
      in
      hand @ extra
      |> List.filter ~f:(fun v -> Int64.(v <> value))
      |> List.dedup_and_sort ~compare:Int64.compare
      |> (fun l -> List.take l max_tries_per_choice)
      |> List.map ~f:(fun value -> Tape.Integer { value; lo; hi })
    end
  | Tape.Float { value; lo; hi } ->
    if Float.(lo = hi) then []
    else begin
      let target = Tape.clamp_float 0. ~lo ~hi in
      let rand = Splittable_random.of_int seed in
      let extra =
        List.init extra_random_samples ~f:(fun _ ->
          Splittable_random.float rand ~lo ~hi)
      in
      (target :: lo :: hi :: extra)
      |> List.filter ~f:(fun v -> Float.(v <> value) && not (Float.is_nan v))
      |> List.dedup_and_sort ~compare:Float.compare
      |> (fun l -> List.take l max_tries_per_choice)
      |> List.map ~f:(fun value -> Tape.Float { value; lo; hi })
    end

let positions_of (image : Tape.image) : (int * Tape.key * int * Tape.choice) list
  =
  List.concat_map
    (List.range 0 (Tape_engine.seg_count image))
    ~f:(fun seg ->
      let arr = Tape_engine.seg_get image seg in
      let key = if seg = 0 then Tape.root else fst image.streams.(seg - 1) in
      List.init (Array.length arr) ~f:(fun idx -> (seg, key, idx, arr.(idx))))

(* One perturbation: replace the choice at [(seg, idx)] with [candidate]
   and nothing else, replay, and classify the result. [`Untestable]
   covers both an overrun (the edit truncated generation before the
   test ran) and a misalignment (the tape resynchronized somewhere,
   so more than the intended choice may have changed) -- neither is
   evidence about THIS choice specifically, so neither counts toward
   [Varies] or against it. *)
let try_candidate (type a) ~(gen : a Base_quickcheck.Generator.t) ~size
    ~(test : a -> bool) (image : Tape.image) seg idx candidate :
    [ `Untestable | `Passed | `Still_failing of a ] =
  let arr = Tape_engine.seg_get image seg in
  let proposal =
    Tape_engine.seg_set image seg (Tape_engine.with_choice arr idx candidate)
  in
  let tape = Tape.create () in
  Tape.start_replay_image ~policy:Tape.Consume tape proposal;
  let value, tested, out =
    Tape_engine.run_and_test ~tape ~gen ~size
      ~seed:Tape_engine.replay_fresh_seed ~test
  in
  match tested with
  | None -> `Untestable
  | Some verdict ->
    if out.Tape.overrun || out.Tape.misaligned then `Untestable
    else (
      match verdict with
      | Tape_stats.Case_passed | Tape_stats.Case_invalid -> `Passed
      | Tape_stats.Case_failed -> `Still_failing value)

type 'a item =
  { seg : int
  ; stream_key : Tape.key
  ; index : int
  ; original : Tape.choice
  ; mutable remaining : Tape.choice list
  ; mutable found : 'a list
  ; mutable tries : int
  }

let analyze (type a) ~(gen : a Base_quickcheck.Generator.t) ~size
    ~(test : a -> bool) ?(budget = default_budget) (image : Tape.image) : a t
  =
  let items =
    List.filter_map (positions_of image) ~f:(fun (seg, key, idx, choice) ->
      match choice with
      | Tape.Marker -> None
      | _ ->
        (* Deterministic per-position seed: reproducible across runs,
           independent of wall-clock or process state. *)
        let seed = Stdlib.Hashtbl.hash (seg, idx, key) in
        Some
          { seg
          ; stream_key = key
          ; index = idx
          ; original = choice
          ; remaining = candidates_for choice ~seed
          ; found = []
          ; tries = 0
          })
  in
  let used = ref 0 in
  let item_wants_more it =
    (not (List.is_empty it.remaining))
    && List.length it.found < max_examples_per_choice
  in
  let work_left () = List.exists items ~f:item_wants_more in
  (* Round-robin, one candidate per item per round: every choice gets a
     fair first look before any choice gets a second, so a budget that
     runs out partway through still leaves every choice with at least
     one try (when budget >= choice count) rather than exhausting the
     first few choices' full quota and leaving the rest completely
     untried. *)
  while !used < budget && work_left () do
    List.iter items ~f:(fun it ->
      if !used < budget && item_wants_more it then
        match it.remaining with
        | [] -> ()
        | c :: rest -> (
          it.remaining <- rest;
          it.tries <- it.tries + 1;
          Int.incr used;
          match try_candidate ~gen ~size ~test image it.seg it.index c with
          | `Still_failing v -> it.found <- it.found @ [ v ]
          | `Passed | `Untestable -> ()))
  done;
  let complete = List.for_all items ~f:(fun it -> not (item_wants_more it)) in
  let choices =
    List.map items ~f:(fun it ->
      let outcome =
        if not (List.is_empty it.found) then Varies { examples = it.found }
        else if it.tries = 0 && List.is_empty it.remaining then
          No_alternative_possible
        else No_variation_found
      in
      { seg = it.seg
      ; stream_key = it.stream_key
      ; index = it.index
      ; original = it.original
      ; outcome
      ; tries = it.tries
      })
  in
  { choices; budget; used = !used; complete }

let string_of_choice = function
  | Tape.Integer { value; lo; hi } ->
    Stdlib.Printf.sprintf "int %Ld  (range [%Ld, %Ld])" value lo hi
  | Tape.Float { value; lo; hi } ->
    Stdlib.Printf.sprintf "float %f  (range [%f, %f])" value lo hi
  | Tape.Bool b -> Stdlib.Printf.sprintf "bool %b" b
  | Tape.Marker -> "marker"

let string_of_key (k : Tape.key) =
  if List.is_empty k then "main"
  else
    String.concat ~sep:"."
      (List.map k ~f:(function
        | Tape.Split n -> Stdlib.Printf.sprintf "split%d" n
        | Tape.Salt s -> Stdlib.Printf.sprintf "salt%d" s))

(* Human-readable report. [sexp_of] converts the regenerated value type
   so a "varies freely" verdict can be shown next to concrete
   alternative values -- the best available substitute for a semantic
   component name, since the engine has no type-level view of what a
   tape position corresponds to in the generator's output; showing the
   actual regenerated values lets a reader map the choice to "the
   second tuple element" (or wherever) themselves. *)
let to_string_hum (type a) ~(sexp_of : a -> Sexp.t) (t : a t) : string =
  let buf = Buffer.create 1024 in
  let add fmt = Stdlib.Printf.ksprintf (Buffer.add_string buf) fmt in
  add
    "explain: free-variation analysis of the minimal example (budget \
     %d, used %d/%d%s)\n"
    t.budget t.used t.budget
    (if t.complete then ""
     else ", budget exhausted before every choice got a full check");
  add
    "  Each choice below was perturbed on its own, holding every other \
     recorded choice fixed, and the test re-run. \"varies freely\" means \
     at least one alternative value at that position still failed the \
     test -- that part of the example is not what makes it fail. \"no \
     variation found\" is a negative result from a BOUNDED search, not \
     proof the choice is load-bearing: if there is nothing clearly \
     suspicious, we refuse the temptation to guess.\n";
  List.iter t.choices ~f:(fun cr ->
    let loc = Stdlib.Printf.sprintf "%s[%d]" (string_of_key cr.stream_key) cr.index in
    match cr.outcome with
    | No_alternative_possible ->
      add "  %-14s %-30s -- only one legal value; freedom is not applicable\n"
        loc (string_of_choice cr.original)
    | No_variation_found ->
      add
        "  %-14s %-30s -- no variation found in %d tr%s (may still be free; \
         search was bounded)\n"
        loc (string_of_choice cr.original) cr.tries
        (if cr.tries = 1 then "y" else "ies")
    | Varies { examples } ->
      add "  %-14s %-30s -- VARIES FREELY (%d/%d tries still failed), e.g.:\n"
        loc (string_of_choice cr.original) (List.length examples) cr.tries;
      List.iter examples ~f:(fun v ->
        add "      still fails with: %s\n" (Sexp.to_string (sexp_of v))));
  Buffer.contents buf

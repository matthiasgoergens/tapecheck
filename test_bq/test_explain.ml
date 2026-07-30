(* Tape_explain: free-variation analysis over a minimal tape image.
   Deterministic unit tests built directly on hand-constructed images
   (rather than routing through Tape_engine.run's random search), so
   these do not depend on generation luck. *)

open! Base
module G = Base_quickcheck.Generator

let check name cond = if not cond then failwith ("FAILED: " ^ name)

let outcome_name = function
  | Tape_explain.Varies _ -> "Varies"
  | Tape_explain.No_variation_found -> "No_variation_found"
  | Tape_explain.No_alternative_possible -> "No_alternative_possible"

let () =
  (* A single scalar choice where exactly one value (7) fails the test:
     every alternative in [0, 50] makes the test pass, so this must be
     reported as no variation found -- the choice is load-bearing. *)
  let gen = G.int_uniform_inclusive 0 50 in
  let image =
    Tape.image_of_main [| Tape.Integer { value = 7L; lo = 0L; hi = 50L } |]
  in
  let test v = v <> 7 in
  let report = Tape_explain.analyze ~gen ~size:10 ~test image in
  check "single load-bearing choice" (List.length report.choices = 1);
  (match report.choices with
  | [ cr ] ->
    check
      (Printf.sprintf "load-bearing choice reported as No_variation_found, \
                        got %s"
         (outcome_name cr.outcome))
      (match cr.outcome with
      | Tape_explain.No_variation_found -> true
      | _ -> false)
  | _ -> failwith "unreachable");
  (* Each choice's own cap is [attempts_per_choice] plus its (small,
     hand-picked) candidate count; +5 covers the largest possible
     candidate list here (no trail is supplied in this test). *)
  check "used <= choices * (attempts_per_choice + 5)"
    (report.used <= List.length report.choices * (report.attempts_per_choice + 5));

  (* The paper's own motivating case, done directly (see also
     demo/explain_demo.ml for the full narrative): pair (a, b), fails
     iff a = 0. Choice 0 (a) is load-bearing; choice 1 (b) is a red
     herring and must be reported as varying freely, with concrete
     example values attached. *)
  let gen2 = G.both (G.int_uniform_inclusive 0 1000) (G.int_uniform_inclusive 0 1000) in
  let image2 =
    Tape.image_of_main
      [| Tape.Integer { value = 0L; lo = 0L; hi = 1000L }
       ; Tape.Integer { value = 0L; lo = 0L; hi = 1000L }
      |]
  in
  let test2 (a, _b) = a <> 0 in
  let report2 = Tape_explain.analyze ~gen:gen2 ~size:10 ~test:test2 image2 in
  check "two choices reported" (List.length report2.choices = 2);
  (match report2.choices with
  | [ a_cr; b_cr ] ->
    check "first (load-bearing) component: No_variation_found"
      (match a_cr.outcome with
      | Tape_explain.No_variation_found -> true
      | _ -> false);
    check "second (free) component: Varies"
      (match b_cr.outcome with Tape_explain.Varies _ -> true | _ -> false);
    (match b_cr.outcome with
    | Tape_explain.Varies { examples } ->
      check "at least one distinct free example found"
        (not (List.is_empty examples));
      check "every free example keeps a = 0 (only b was perturbed)"
        (List.for_all examples ~f:(fun (a, _) -> a = 0))
    | _ -> failwith "unreachable")
  | _ -> failwith "unreachable");

  (* lo = hi: no alternative value exists at all, distinct from a
     search that came up empty. *)
  let gen3 = G.int_uniform_inclusive 5 5 in
  let image3 =
    Tape.image_of_main [| Tape.Integer { value = 5L; lo = 5L; hi = 5L } |]
  in
  let report3 = Tape_explain.analyze ~gen:gen3 ~size:10 ~test:(fun v -> v <> 5) image3 in
  (match report3.choices with
  | [ cr ] ->
    check "single-point range: No_alternative_possible"
      (match cr.outcome with
      | Tape_explain.No_alternative_possible -> true
      | _ -> false);
    check "single-point range: zero tries spent" (cr.tries = 0)
  | _ -> failwith "unreachable");

  (* Budget honesty: attempts_per_choice = 0 must try nothing, spend
     nothing, and say plainly that the search did not complete -- never
     silently report a stronger verdict than it earned. (This is a
     stricter guarantee than Hypothesis's own `range(0 + len(candidates))`,
     which would still spend the free candidates at a configured cap of
     zero; a caller passing 0 here gets literally zero replays.) *)
  let report4 =
    Tape_explain.analyze ~gen:gen2 ~size:10 ~test:test2 ~attempts_per_choice:0
      image2
  in
  check "budget 0: nothing spent" (report4.used = 0);
  check "budget 0: reports incomplete" (not report4.complete);
  check "budget 0: every choice has zero tries"
    (List.for_all report4.choices ~f:(fun cr -> cr.tries = 0));

  (* Rendering: to_string_hum must not crash and must mention both
     verdict words for the mixed case above. *)
  let rendered =
    Tape_explain.to_string_hum ~sexp_of:[%sexp_of: int * int] report2
  in
  check "render mentions VARIES" (String.is_substring rendered ~substring:"VARIES");
  check "render mentions no variation found"
    (String.is_substring rendered ~substring:"no variation found");

  Stdlib.print_endline "all explain tests passed"

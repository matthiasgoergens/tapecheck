open! Base

module Small_int = struct
  type t = int [@@deriving sexp_of]

  let quickcheck_generator =
    Base_quickcheck.Generator.int_uniform_inclusive 0 100

  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

let check name condition =
  if not condition then failwith ("FAILED: " ^ name)

let total_events events =
  List.sum (module Int) events ~f:snd

let () =
  let stats = Tape_test.Stats.create () in
  let empty = Tape_test.Stats.snapshot stats in
  check "new accumulator has no cases"
    (empty.cases_valid = 0
     && empty.cases_invalid = 0
     && empty.cases_failed = 0);
  check "new accumulator has no events or warnings"
    (List.is_empty empty.events && List.is_empty empty.warnings);

  let config =
    { Tape_test.default_config with
      seed = Deterministic "stats-api"
    ; test_count = 100
    ; sizes = Sequence.repeat 10
    }
  in
  let result =
    Tape_test.result
      ~f:(fun value ->
        Tape_test.event "parity"
          ~payload:(if value % 2 = 0 then "even" else "odd");
        Tape_test.assume (value % 2 = 0);
        Ok ())
      ~config ~report:`Silent ~stats (module Small_int)
  in
  check "passing and discarded run succeeds" (Result.is_ok result);
  let before_reuse = Tape_test.Stats.snapshot stats in
  check "snapshot exposes passing cases" (before_reuse.cases_valid > 0);
  check "snapshot exposes discarded cases" (before_reuse.cases_invalid > 0);
  check "snapshot exposes no false failures" (before_reuse.cases_failed = 0);
  check "snapshot event table is sorted"
    (List.equal String.equal
       (List.map before_reuse.events ~f:fst)
       [ "parity: even"; "parity: odd" ]);
  check "events account for every generated case"
    (total_events before_reuse.events
     = before_reuse.cases_valid + before_reuse.cases_invalid);

  let failed =
    Tape_test.result
      ~f:(fun _ -> Error "expected") ~examples:[ 7 ] ~report:`Silent ~stats
      ~config:{ config with test_count = 0 }
      (module Small_int)
  in
  check "explicit failing example fails" (Result.is_error failed);
  let after_reuse = Tape_test.Stats.snapshot stats in
  check "accumulator can be reused" (after_reuse.cases_failed = 1);
  check "earlier snapshots remain immutable" (before_reuse.cases_failed = 0);
  check "reporting remains available without exposing mutation"
    (String.is_substring (Tape_test.Stats.summary_line stats)
       ~substring:"1 failing"
     && not (String.is_empty (Tape_test.Stats.to_string_hum stats)))

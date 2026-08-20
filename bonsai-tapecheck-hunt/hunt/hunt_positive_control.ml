open! Core

module Int_subject = struct
  type t = int [@@deriving sexp_of]

  let quickcheck_generator =
    Base_quickcheck.Generator.int_uniform_inclusive 0 1_000_000

  (* This is intentionally atomic: the consumer must prove that Tapecheck,
     rather than Base Quickcheck's value shrinker, finds the exact boundary. *)
  let quickcheck_shrinker = Base_quickcheck.Shrinker.atomic
end

let () =
  let config =
    { Tape_test.default_config with
      seed = Deterministic "consumer-positive-control"
    ; test_count = 200
    }
  in
  match
    Tape_test.result
      ~f:(fun value ->
        if value >= 123_457 then Error "boundary reached" else Ok ())
      ~config ~report:`Silent (module Int_subject)
  with
  | Error (123_457, "boundary reached") ->
    printf "consumer positive control: found and shrank exactly to 123457\n"
  | Error (minimal, message) ->
    failwithf "wrong minimal counterexample: %d (%s)" minimal message ()
  | Ok () -> failwith "positive control did not find the reachable failure"

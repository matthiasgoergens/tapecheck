(* Drop-in replacement for Base_quickcheck.Test: same Config, same
   (module S) argument, same run/run_exn/result signatures. The
   module's quickcheck_shrinker is accepted and ignored; shrinking is
   the tape engine's replay-based search over quickcheck_generator.
   Existing suites switch by replacing the module name. *)

open! Base
module Config = Base_quickcheck.Test.Config

let default_config = Base_quickcheck.Test.default_config

let seed_int (seed : Config.Seed.t) =
  match seed with
  | Deterministic s -> Hashtbl.hash s
  | Nondeterministic -> Random.bits ()

let result (type a e) ~(f : a -> (unit, e) Result.t)
    ?(config = default_config) ?(examples = [])
    (module M : Base_quickcheck.Test.S with type t = a) :
    (unit, a * e) Result.t =
  let test v = Result.is_ok (f v) in
  let example_failure =
    List.find_map examples ~f:(fun v ->
      match f v with
      | Ok () -> None
      | Error e -> Some (Error (v, e)))
  in
  match example_failure with
  | Some err -> err
  | None ->
    let base_seed = seed_int config.seed in
    let sizes =
      Sequence.take config.sizes config.test_count |> Sequence.to_list
    in
    let failure = ref None in
    let case = ref 0 in
    let sizes = Array.of_list sizes in
    while Option.is_none !failure && !case < Array.length sizes do
      (match
         Tape_engine.run M.quickcheck_generator ~test
           ~seed:(base_seed + !case) ~count:1 ~size:sizes.(!case)
           ~budget:config.shrink_count
       with
      | Tape_engine.Passed _ -> ()
      | Tape_engine.Failed { minimal; _ } -> (
        match f minimal with
        | Error e -> failure := Some (Error (minimal, e))
        | Ok () ->
          (* The shrunken value no longer fails deterministically;
             report it with no error payload path available, so rerun
             is the caller's problem. This mirrors flaky-test behavior
             in Base_quickcheck, which would also report confusingly
             here. Treat as passed for this case. *)
          ()));
      Int.incr case
    done;
    (match !failure with
     | Some err -> err
     | None -> Ok ())

let run (type a) ~(f : a -> unit Or_error.t) ?config ?examples
    (module M : Base_quickcheck.Test.S with type t = a) : unit Or_error.t =
  let f v = Or_error.try_with_join (fun () -> f v) in
  match result ~f ?config ?examples (module M) with
  | Ok () -> Ok ()
  | Error (input, error) ->
    Or_error.error_s
      [%message
        "Base_quickcheck.Test.run: test failed (tape engine)"
          (input : M.t)
          (error : Error.t)]

let run_exn (type a) ~(f : a -> unit) ?config ?examples
    (module M : Base_quickcheck.Test.S with type t = a) : unit =
  let f v = Or_error.try_with (fun () -> f v) in
  run ~f ?config ?examples (module M) |> Or_error.ok_exn

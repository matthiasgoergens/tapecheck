(* Drop-in replacement for Base_quickcheck.Test: same Config, same
   (module S) argument, same run/run_exn/result signatures. The
   module's quickcheck_shrinker is accepted and ignored; shrinking is
   the tape engine's replay-based search over quickcheck_generator.
   Existing suites switch by replacing the module name. *)

open! Base
module Config = Base_quickcheck.Test.Config

let default_config = Base_quickcheck.Test.default_config

(* RO6 (outreach/ro-roadmap.md): re-exported here, alongside [run]/
   [run_exn]/[result], because this is the module a suite actually
   opens/qualifies against -- the natural place for the property
   function to reach [assume]/[event], mirroring how Hypothesis exports
   both from the top-level [hypothesis] package rather than a separate
   "runner" module. See [Tape_stats] for the implementation. *)
let assume = Tape_stats.assume
let event = Tape_stats.event

(* How much of the statistics report to print, on every run
   (pass or fail) unless [`Silent]:
   - [`Silent]: nothing (the pre-RO6 behavior).
   - [`Summary] (default): one line -- cases tried, valid, DISCARDED,
     failing, and which health checks fired, if any. This is the direct
     answer to the paper's "OCaml's QuickCheck hides output when tests
     succeed" (outreach/paper-full.txt, quoted in ro-roadmap.md): it
     requires no change to how a suite invokes its tests to appear.
   - [`Full]: the summary plus every event() tag and its count, the
     generate/run/shrink time split, and shrink call counts -- the
     analogue of --hypothesis-show-statistics. *)
type report_level =
  [ `Silent
  | `Summary
  | `Full
  ]

let seed_int (seed : Config.Seed.t) =
  match seed with
  | Deterministic s -> Hashtbl.hash s
  | Nondeterministic -> Random.bits ()

(* Regression files: one lowercase-hex serialized tape per line,
   optional trailing "# comment". Replaying a tape regenerates the
   exact persisted failure through the generator, independent of seeds
   and robust to distribution changes. A line that no longer parses or
   generates is a loud error: a regression entry that stops guarding
   must not silently pass. *)
module Regressions = struct
  let hex_of_string s =
    String.concat_map s ~f:(fun c -> Printf.sprintf "%02x" (Char.to_int c))

  let string_of_hex h =
    if String.length h % 2 <> 0 then None
    else
      Option.try_with (fun () ->
        String.init
          (String.length h / 2)
          ~f:(fun i ->
            Char.of_int_exn
              (Int.of_string ("0x" ^ String.sub h ~pos:(i * 2) ~len:2))))

  (* Line format: "<hex tape> @<size> # comment". The size the failure
     was recorded at matters: base_quickcheck combinators read ~size
     for control flow (length bounds, recursion choices), so replaying
     at a different size can regenerate a different value. Legacy lines
     without @size replay at the historical default of 30. *)
  let load path =
    match Stdlib.Sys.file_exists path with
    | false -> Ok []
    | true ->
      let lines = Stdlib.In_channel.with_open_text path Stdlib.In_channel.input_lines in
      List.filter_mapi lines ~f:(fun lineno line ->
        let payload =
          match String.lsplit2 line ~on:'#' with
          | Some (before, _) -> String.strip before
          | None -> String.strip line
        in
        if String.is_empty payload then None
        else begin
          let hex, size =
            match String.lsplit2 payload ~on:'@' with
            | Some (hex, size_str) ->
              (String.strip hex, Int.of_string_opt (String.strip size_str))
            | None -> (payload, Some 30)
          in
          match
            (Option.bind (string_of_hex hex) ~f:Tape.deserialize_image, size)
          with
          | Some image, Some size -> Some (Ok (lineno + 1, size, image))
          | _ -> Some (Error (lineno + 1))
        end)
      |> Result.combine_errors
      |> Result.map_error ~f:(fun bad_lines ->
           Error.create_s
             [%message
               "corrupt regression tape; delete the stale line to continue"
                 (path : string)
                 (bad_lines : int list)])

  let append path ~image ~size ~comment =
    Stdlib.Out_channel.with_open_gen
      [ Open_append; Open_creat; Open_text ] 0o644 path
      (fun oc ->
        Stdlib.Printf.fprintf oc "%s @%d # %s\n"
          (hex_of_string (Tape.serialize_image image))
          size comment)
end

let result (type a e) ~(f : a -> (unit, e) Result.t)
    ?(config = default_config) ?(examples = []) ?regressions
    ?(realign = `Both) ?(explain = false)
    ?(explain_budget = Tape_explain.default_budget)
    ?(report : report_level = `Summary) ?(suppress_health_check = [])
    ?stats (module M : Base_quickcheck.Test.S with type t = a) :
    (unit, a * e) Result.t =
  (* RO6: [stats]/[health] are shared across every [Tape_engine.run]
     call in the fresh-generation loop below (one call per size value,
     config.test_count of them -- 10,000 by default), so the discard
     count and the health-check window both see "the whole test run",
     not just its first generated case. *)
  let stats = match stats with Some s -> s | None -> Tape_engine.no_stats () in
  let health = Tape_health.create () in
  let print_report () =
    match report with
    | `Silent -> ()
    | `Summary -> Stdlib.print_endline (Tape_engine.stats_summary_line stats)
    | `Full -> Stdlib.print_string (Tape_engine.stats_to_string_hum stats)
  in
  let test v = Result.is_ok (f v) in
  (* Persisted failures replay first: they are the cheapest and the
     most likely to fail again. *)
  (* Replay EVERY regression entry before deciding anything: a real
     counterexample from any entry is reported immediately, while
     entries that replay to passing values are collected and raised at
     the END of the whole run, so one stale line neither hides a
     failure in a later entry nor blocks fresh generation (the
     blast-radius lesson from the sibling Rust engine's review). *)
  let stale_entries = ref [] in
  let regression_failure =
    match regressions with
    | None -> None
    | Some path ->
      (match Regressions.load path with
       | Error err -> Error.raise err
       | Ok entries ->
         List.find_map entries ~f:(fun (line, size, image) ->
           (* Apply the property while the tape is live: a persisted
              failure that involves a generated function only
              reproduces if the function's streams stay
              tape-controlled during [f]. *)
           let value, verdict =
             Tape_engine.replay_image_and_apply M.quickcheck_generator
               ~size image ~f
           in
           match verdict with
           | Error e -> Some (Error (value, e))
           | Ok () ->
             stale_entries := line :: !stale_entries;
             None))
  in
  let finish_run (result : (unit, a * e) Result.t) : (unit, a * e) Result.t =
    match (result, List.rev !stale_entries, regressions) with
    | Error _, _, _ | _, [], _ | _, _, None -> result
    | Ok (), stale, Some path ->
      (* Everything passes, but entries stopped guarding: loud, with
         the complete list, after full coverage ran. *)
      Error.raise_s
        [%message
          "regression tape entries replay to passing values; the bugs \
           they guarded may be fixed (delete the lines) or the \
           generator has drifted (re-record them)"
            (path : string)
            ~lines:(stale : int list)]
  in
  match regression_failure with
  | Some err -> err
  | None ->
    finish_run
      @@
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
    if List.length sizes < config.test_count then
      Error.raise_s
        [%message
          "insufficient size values for test count"
            ~test_count:(config.test_count : int)
            ~sizes_available:(List.length sizes : int)];
    let failure = ref None in
    let case = ref 0 in
    let sizes = Array.of_list sizes in
    while Option.is_none !failure && !case < Array.length sizes do
      (match
         Tape_engine.run M.quickcheck_generator ~test ~realign
           ~seed:(base_seed + !case) ~count:1 ~size:sizes.(!case)
           ~budget:config.shrink_count ~stats ~health ~suppress_health_check
       with
      | Tape_engine.Passed _ -> ()
      | Tape_engine.Failed { minimal; image; _ } -> (
        match f minimal with
        | Error e ->
          Option.iter regressions ~f:(fun path ->
            Regressions.append path ~image ~size:sizes.(!case)
              ~comment:(Sexp.to_string (M.sexp_of_t minimal)));
          (* Phase.explain, switched off by default (?explain:false):
             free-variation analysis over the just-shrunk minimal
             example, printed for a human the way Hypothesis prints its
             own explanation alongside the falsifying example. Off by
             default because it is pure overhead on top of a failing
             run that is about to be reported anyway; on, it costs a
             bounded number of extra replays (Tape_explain.default_budget,
             configurable via ?explain_budget). *)
          if explain then
            Stdlib.print_string
              (Tape_explain.to_string_hum ~sexp_of:M.sexp_of_t
                 (Tape_explain.analyze ~gen:M.quickcheck_generator
                    ~size:sizes.(!case) ~test ~budget:explain_budget image));
          failure := Some (Error (minimal, e))
        | Ok () ->
          (* The shrunken value no longer fails deterministically;
             report it with no error payload path available, so rerun
             is the caller's problem. This mirrors flaky-test behavior
             in Base_quickcheck, which would also report confusingly
             here. Treat as passed for this case. *)
          ()));
      Int.incr case
    done;
    print_report ();
    (match !failure with
     | Some err -> err
     | None -> Ok ())

(* [Or_error.try_with]/[try_with_join] catch EVERY exception, including
   [Tape_stats.Invalid_example] -- but that one must propagate all the
   way down into [Tape_engine.run_and_test]'s own handler, or
   [Tape_test.assume] would silently stop working the moment a property
   is run through [run]/[run_exn] rather than [result] (whose ~f is the
   caller's own, never pre-wrapped). These behave exactly like their
   Or_error counterparts for every other exception, but re-raise
   [Invalid_example] instead of converting it to an [Error]. *)
let try_with_join_preserving_assume f =
  match f () with
  | result -> result
  | exception Tape_stats.Invalid_example -> raise Tape_stats.Invalid_example
  | exception exn -> Or_error.of_exn exn

let try_with_preserving_assume f =
  match f () with
  | result -> Ok result
  | exception Tape_stats.Invalid_example -> raise Tape_stats.Invalid_example
  | exception exn -> Or_error.of_exn exn

let run (type a) ~(f : a -> unit Or_error.t) ?config ?examples ?regressions
    ?realign ?explain ?explain_budget ?report ?suppress_health_check ?stats
    (module M : Base_quickcheck.Test.S with type t = a) : unit Or_error.t =
  let f v = try_with_join_preserving_assume (fun () -> f v) in
  match
    result ~f ?config ?examples ?regressions ?realign ?explain ?explain_budget
      ?report ?suppress_health_check ?stats (module M)
  with
  | Ok () -> Ok ()
  | Error (input, error) ->
    Or_error.error_s
      [%message
        "Base_quickcheck.Test.run: test failed (tape engine)"
          (input : M.t)
          (error : Error.t)]

let run_exn (type a) ~(f : a -> unit) ?config ?examples ?regressions ?realign
    ?explain ?explain_budget ?report ?suppress_health_check ?stats
    (module M : Base_quickcheck.Test.S with type t = a) : unit =
  let f v = try_with_preserving_assume (fun () -> f v) in
  run ~f ?config ?examples ?regressions ?realign ?explain ?explain_budget
    ?report ?suppress_health_check ?stats (module M)
  |> Or_error.ok_exn

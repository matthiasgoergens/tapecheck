open! Base

let check name condition = if not condition then failwith ("FAILED: " ^ name)

type Sr_real.span_label +=
  | Outer
  | Inner

exception Body_failure
exception Start_callback_failure
exception Stop_callback_failure

let () =
  let expected = Sr_real.of_int 404 in
  let delegating =
    Sr_real.with_intercept (Sr_real.of_int 404) (Sr_real.Intercept.create ())
  in
  check "constructed delegating observer is active"
    (Sr_real.Intercept.is_active delegating);
  check "default bool observer delegates"
    (Bool.equal (Sr_real.bool delegating) (Sr_real.bool expected));
  check "default integer observer delegates"
    (Int.equal
       (Sr_real.int delegating ~lo:(-100) ~hi:1_000)
       (Sr_real.int expected ~lo:(-100) ~hi:1_000));
  check "default float observer delegates"
    (Float.equal
       (Sr_real.float delegating ~lo:(-1.) ~hi:2.)
       (Sr_real.float expected ~lo:(-1.) ~hi:2.));
  check "default weighted observer delegates"
    (Bool.equal
       (Sr_real.bool_with_probability delegating ~probability:0.37)
       (Sr_real.bool_with_probability expected ~probability:0.37));
  check "default split child is unobserved"
    (not (Sr_real.Intercept.is_active (Sr_real.split delegating)));
  Sr_real.perturb delegating 17;
  check "default perturb callback retains the observer"
    (Sr_real.Intercept.is_active delegating);

  let events = ref [] in
  let weighted_calls = ref [] in
  let default_span_start label ~deletable ~discardable:_ ~descendable
    ~reorderable:_ =
    events :=
      (match label with
       | Outer -> "start outer"
       | Inner when descendable -> "start inner descendable"
       | Inner when deletable -> "start inner deletable"
       | Inner -> "start inner"
       | _ -> "start unknown")
      :: !events
  in
  let default_span_stop ~deletable:_ ~discardable:_ ~descendable:_
    ~reorderable:_ ~discarded:_ () =
    events := "stop" :: !events
  in
  let make_hooks ~on_span_start ~on_span_stop =
    let rec loop () =
      Sr_real.Intercept.create
        ~bool_with_probability:
        (fun state ~probability ~forced ~default ->
          weighted_calls := (probability, forced) :: !weighted_calls;
          default state ~probability)
        ~on_span_start
        ~on_span_stop
        ~on_split:(fun () -> Some (loop ()))
        ~on_perturb:(fun _ -> Some (loop ()))
        ()
    in
    loop ()
  in
  let hooks =
    make_hooks ~on_span_start:default_span_start
      ~on_span_stop:default_span_stop
  in
  let bare = Sr_real.of_int 1 in
  let ran = ref false in
  Sr_real.with_span bare Outer ~f:(fun () -> ran := true);
  check "unattached with_span runs its body" !ran;
  check "unattached with_span emits no callbacks" (List.is_empty !events);

  let attached = Sr_real.with_intercept bare hooks in
  Sr_real.with_span attached Outer ~f:(fun () ->
    Sr_real.with_span ~deletable:true attached Inner ~f:(fun () -> ()));
  check "nested spans are properly bracketed"
    (List.equal
       String.equal
       (List.rev !events)
       [ "start outer"; "start inner deletable"; "stop"; "stop" ]);
  events := [];
  Sr_real.with_span ~descendable:true attached Inner ~f:(fun () -> ());
  check "descendable capability reaches the observer"
    (List.equal String.equal (List.rev !events)
       [ "start inner descendable"; "stop" ]);

  events := [];
  let raised =
    match
      Result.try_with (fun () ->
        Sr_real.with_span attached Outer ~f:(fun () -> raise Body_failure))
    with
    | Error Body_failure -> true
    | Error _ | Ok _ -> false
  in
  check "body exception propagates" raised;
  check "exceptional span is still closed"
    (List.equal String.equal (List.rev !events) [ "start outer"; "stop" ]);

  let body_ran = ref false in
  let start_failure_hooks =
    make_hooks
      ~on_span_start:
        (fun _ ~deletable:_ ~discardable:_ ~descendable:_ ~reorderable:_ ->
          raise Start_callback_failure)
      ~on_span_stop:default_span_stop
  in
  let start_failure_state = Sr_real.with_intercept bare start_failure_hooks in
  check "start callback exception propagates"
    (match
       Result.try_with (fun () ->
         Sr_real.with_span start_failure_state Outer ~f:(fun () -> body_ran := true))
     with
     | Error Start_callback_failure -> true
     | Error _ | Ok _ -> false);
  check "start callback exception prevents the body" (not !body_ran);
  let stop_failure_hooks =
    make_hooks
      ~on_span_start:default_span_start
      ~on_span_stop:
        (fun ~deletable:_ ~discardable:_ ~descendable:_ ~reorderable:_ ~discarded:_ () ->
          raise Stop_callback_failure)
  in
  let stop_failure_state = Sr_real.with_intercept bare stop_failure_hooks in
  check "stop callback exception propagates"
    (match
       Result.try_with (fun () ->
         Sr_real.with_span stop_failure_state Outer ~f:(fun () -> ()))
     with
     | Error Stop_callback_failure -> true
     | Error _ | Ok _ -> false);
  check "body and stop callback exceptions are both preserved"
    (match
       Result.try_with (fun () ->
         Sr_real.with_span stop_failure_state Outer ~f:(fun () -> raise Body_failure))
     with
     | Error (Exn.Finally (Body_failure, Stop_callback_failure)) -> true
     | Error _ | Ok _ -> false);

  ignore (Sr_real.bool_with_probability attached ~probability:0.25 : bool);
  check "weighted hook receives the requested probability"
    (Poly.equal !weighted_calls [ 0.25, None ]);
  ignore (Sr_real.bool_with_probability attached ~probability:0. : bool);
  ignore (Sr_real.bool_with_probability attached ~probability:1. : bool);
  ignore
    (Sr_real.bool_with_probability attached ~probability:0.25 ~forced:false
     : bool);
  check "forced choices reach the hook with their constraint"
    (Poly.equal
       !weighted_calls
       [ 0.25, Some false; 1., Some true; 0., Some false; 0.25, None ]);
  let forced_state = Sr_real.of_int 17 in
  let untouched_state = Sr_real.copy forced_state in
  ignore (Sr_real.bool_with_probability forced_state ~probability:0. : bool);
  ignore (Sr_real.bool_with_probability forced_state ~probability:1. : bool);
  check "forced probabilities do not advance the random state"
    (Int64.equal
       (Sr_real.int64 forced_state ~lo:Int64.min_value ~hi:Int64.max_value)
       (Sr_real.int64 untouched_state ~lo:Int64.min_value ~hi:Int64.max_value));
  check "impossible forced value is rejected"
    (Result.is_error
       (Result.try_with (fun () ->
          ignore
            (Sr_real.bool_with_probability forced_state ~probability:0.
               ~forced:true
             : bool))));
  check "NaN probability is rejected"
    (Result.is_error
       (Result.try_with (fun () ->
          ignore
            (Sr_real.bool_with_probability attached ~probability:Float.nan
             : bool))));
  List.iter [ -0.01; 1.01; Float.infinity; Float.neg_infinity ] ~f:(fun probability ->
    check "out-of-range probability is rejected"
      (Result.is_error
         (Result.try_with (fun () ->
            ignore
              (Sr_real.bool_with_probability attached ~probability
               : bool)))));
  Stdlib.print_endline "test_sr_seam: all passed"
;;

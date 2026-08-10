open! Base

let check name condition = if not condition then failwith ("FAILED: " ^ name)

type Sr_real.span_label +=
  | Outer
  | Inner

exception Body_failure

let () =
  let events = ref [] in
  let weighted_calls = ref [] in
  let rec hooks : Sr_real.Intercept.t =
    { int64 = (fun state ~lo ~hi ~default -> default state ~lo ~hi)
    ; float = (fun state ~lo ~hi ~default -> default state ~lo ~hi)
    ; unit_float = (fun state ~default -> default state)
    ; bool = (fun state ~default -> default state)
    ; bool_with_probability =
        (fun state ~probability ~default ->
          weighted_calls := probability :: !weighted_calls;
          default state ~probability)
    ; on_span_start =
        (fun label ->
          events :=
            (match label with
             | Outer -> "start outer"
             | Inner -> "start inner"
             | _ -> "start unknown")
            :: !events)
    ; on_span_stop = (fun () -> events := "stop" :: !events)
    ; on_split = (fun () -> Some hooks)
    ; on_perturb = (fun _ -> Some hooks)
    }
  in
  let bare = Sr_real.of_int 1 in
  let ran = ref false in
  Sr_real.with_span bare Outer ~f:(fun () -> ran := true);
  check "unattached with_span runs its body" !ran;
  check "unattached with_span emits no callbacks" (List.is_empty !events);

  let attached = Sr_real.with_intercept bare hooks in
  Sr_real.with_span attached Outer ~f:(fun () ->
    Sr_real.with_span attached Inner ~f:(fun () -> ()));
  check "nested spans are properly bracketed"
    (List.equal
       String.equal
       (List.rev !events)
       [ "start outer"; "start inner"; "stop"; "stop" ]);

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

  ignore (Sr_real.bool_with_probability attached ~probability:0.25 : bool);
  check "weighted hook receives the requested probability"
    (List.equal Float.equal !weighted_calls [ 0.25 ]);
  ignore (Sr_real.bool_with_probability attached ~probability:0. : bool);
  ignore (Sr_real.bool_with_probability attached ~probability:1. : bool);
  check "forced probabilities bypass the hook"
    (List.equal Float.equal !weighted_calls [ 0.25 ]);
  check "NaN probability is rejected"
    (Result.is_error
       (Result.try_with (fun () ->
          ignore
            (Sr_real.bool_with_probability attached ~probability:Float.nan
             : bool))));
  Stdlib.print_endline "test_sr_seam: all passed"
;;

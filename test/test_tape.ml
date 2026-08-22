let check name cond = if not cond then failwith ("FAILED: " ^ name)

(* A tiny deterministic "generator": draws an int in [0,100], a bool,
   and if the bool is true another int in [0,10]. *)
let generate tape ~ints ~bools =
  let next_int = ref 0 and next_bool = ref 0 in
  (* [draw_int]'s edge-case bias (tape/tape.ml) rolls an auxiliary
     [0,15] die before drawing the "real" value, to decide between a
     boundary candidate and a plain sample; both draws in this file are
     far narrower than the bit-size threshold (2^24), so forcing that
     roll away from 0 always selects the plain-uniform branch, which
     then calls back with the ACTUAL [lo, hi] this test cares about. *)
  let sample_int arr r ~lo ~hi =
    if Int64.equal lo 0L && Int64.equal hi 15L then 5L (* force non-boundary roll *)
    else begin
      ignore hi;
      let v = arr.(!r mod Array.length arr) in
      incr r;
      Int64.of_int v
    end
  in
  let a = Tape.draw_int tape ~lo:0L ~hi:100L ~sample:(sample_int ints next_int) in
  let b = Tape.draw_bool tape ~sample:(fun () -> let v = bools.(!next_bool mod Array.length bools) in incr next_bool; v) in
  let c =
    if b then Tape.draw_int tape ~lo:0L ~hi:10L ~sample:(sample_int ints next_int)
    else 0L
  in
  (a, b, c)

let () =
  (* Recording captures the draws. *)
  let tape = Tape.create () in
  Tape.start_recording tape;
  let v1 = generate tape ~ints:[| 42; 7 |] ~bools:[| true |] in
  let out1 = Tape.finish tape in
  check "recorded three choices" (Array.length out1.Tape.choices = 3);
  check "value" (v1 = (42L, true, 7L));

  (* Replaying the recorded tape reproduces the value exactly, even
     with different underlying "randomness". *)
  Tape.start_replay tape out1.Tape.choices;
  let v2 = generate tape ~ints:[| 99; 99 |] ~bools:[| false |] in
  let out2 = Tape.finish tape in
  check "replay reproduces" (v2 = v1);
  check "replay not overrun" (not out2.Tape.overrun);
  (* [equal_choices]: "identically" is a claim about the recording, and
     compare_shortlex is the shrink order, which can rank two different
     recordings equal. *)
  check "replay re-records identically"
    (Tape.equal_choices out1.Tape.choices out2.Tape.choices);

  (* Deletable span boundaries are runtime metadata over half-open choice
     ranges.  They are reconstructed on replay rather than becoming part of
     the persisted image.  An observational outer span is filtered without
     disturbing its nested deletable range. *)
  Tape.start_recording tape;
  Tape.on_span_start tape ~stream:Tape.root ~label:17 ~deletable:false
    ~discardable:false ~descendable:false ~reorderable:false;
  ignore
    (Tape.draw_int tape ~lo:0L ~hi:10L
       ~sample:(fun ~lo:_ ~hi:_ -> 4L)
     : int64);
  Tape.on_span_start tape ~stream:Tape.root ~label:23 ~deletable:true
    ~discardable:false ~descendable:false ~reorderable:false;
  ignore (Tape.draw_bool tape ~sample:(fun () -> true) : bool);
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:true ~discardable:false
    ~descendable:false ~reorderable:false ~discarded:false;
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:false ~discardable:false
    ~descendable:false ~reorderable:false ~discarded:false;
  let spanned = Tape.finish tape in
  check "only deletable nested spans are retained"
    (Array.to_list spanned.Tape.spans
     = [ { Tape.stream = Tape.root
         ; label = 23
         ; deletable = true
         ; discarded = false
         ; descendable = false
         ; reorderable = false
         ; id = 0
         ; parent = None
         ; depth = 0
         ; start = 1
         ; stop = 2
         }
       ]);
  Tape.start_replay_image tape spanned.Tape.image;
  Tape.on_span_start tape ~stream:Tape.root ~label:17 ~deletable:false
    ~discardable:false ~descendable:false ~reorderable:false;
  ignore
    (Tape.draw_int tape ~lo:0L ~hi:10L
       ~sample:(fun ~lo:_ ~hi:_ -> 9L)
     : int64);
  Tape.on_span_start tape ~stream:Tape.root ~label:23 ~deletable:true
    ~discardable:false ~descendable:false ~reorderable:false;
  ignore (Tape.draw_bool tape ~sample:(fun () -> false) : bool);
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:true ~discardable:false
    ~descendable:false ~reorderable:false ~discarded:false;
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:false ~discardable:false
    ~descendable:false ~reorderable:false ~discarded:false;
  let respanned = Tape.finish tape in
  check "replay reconstructs span boundaries"
    (Array.to_list spanned.Tape.spans = Array.to_list respanned.Tape.spans);

  Tape.start_recording tape;
  Tape.on_span_start tape ~stream:Tape.root ~label:29 ~deletable:false
    ~discardable:true ~descendable:false ~reorderable:false;
  ignore
    (Tape.draw_int tape ~lo:0L ~hi:10L
       ~sample:(fun ~lo:_ ~hi:_ -> 6L)
     : int64);
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:false ~discardable:true
    ~descendable:false ~reorderable:false ~discarded:true;
  let discarded = Tape.finish tape in
  check "exceptional discardable span is retained"
    (match Array.to_list discarded.Tape.spans with
     | [ span ] ->
       span.label = 29
       && span.start = 0
       && span.stop = 1
       && span.discarded
       && not span.deletable
       && not span.descendable
     | _ -> false);
  Tape.start_recording tape;
  Tape.on_span_start tape ~stream:Tape.root ~label:29 ~deletable:false
    ~discardable:true ~descendable:false ~reorderable:false;
  ignore (Tape.draw_bool tape ~sample:(fun () -> false) : bool);
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:false ~discardable:true
    ~descendable:false ~reorderable:false ~discarded:false;
  let successful = Tape.finish tape in
  check "successful discardable span is filtered"
    (Array.length successful.Tape.spans = 0);
  Tape.start_recording tape;
  Tape.on_span_start tape ~stream:Tape.root ~label:31 ~deletable:false
    ~discardable:false ~descendable:true ~reorderable:false;
  ignore (Tape.draw_bool tape ~sample:(fun () -> true) : bool);
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:false ~discardable:false
    ~descendable:true ~reorderable:false ~discarded:false;
  let descendable = Tape.finish tape in
  check "successful descendable span is retained"
    (match Array.to_list descendable.Tape.spans with
     | [ span ] -> span.label = 31 && span.descendable && not span.discarded
     | _ -> false);
  Tape.start_recording tape;
  Tape.on_span_start tape ~stream:Tape.root ~label:31 ~deletable:false
    ~discardable:false ~descendable:true ~reorderable:false;
  ignore (Tape.draw_bool tape ~sample:(fun () -> true) : bool);
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:false ~discardable:false
    ~descendable:true ~reorderable:false ~discarded:true;
  let failed_descendable = Tape.finish tape in
  check "failed descendable span is not a replacement candidate"
    (Array.length failed_descendable.Tape.spans = 0);
  Tape.start_recording tape;
  Tape.on_span_start tape ~stream:Tape.root ~label:37 ~deletable:true
    ~discardable:true ~descendable:true ~reorderable:false;
  ignore (Tape.draw_bool tape ~sample:(fun () -> true) : bool);
  Tape.on_span_stop tape ~stream:Tape.root ~deletable:true ~discardable:true
    ~descendable:true ~reorderable:false ~discarded:true;
  let failed_actionable = Tape.finish tape in
  check "failed actionable span is retained only as discarded input"
    (match Array.to_list failed_actionable.Tape.spans with
     | [ span ] ->
       span.discarded && not span.deletable && not span.descendable
     | _ -> false);

  (* Editing a choice steers generation: flip the bool to false and the
     dependent draw disappears; the output tape is shorter, hence
     shortlex-smaller. *)
  let edited = Array.copy out1.Tape.choices in
  edited.(1) <- Tape.Bool false;
  Tape.start_replay tape edited;
  let v3 = generate tape ~ints:[| 99; 99 |] ~bools:[| true |] in
  let out3 = Tape.finish tape in
  check "edited bool steers generation" (v3 = (42L, false, 0L));
  check "shorter tape wins shortlex"
    (Tape.compare_shortlex out3.Tape.choices out1.Tape.choices < 0);

  (* Values clamp into their constraints on replay. *)
  let clamped = Array.copy out1.Tape.choices in
  clamped.(0) <- Tape.Integer { value = 5000L; lo = 0L; hi = 100L };
  Tape.start_replay tape clamped;
  let v4 = generate tape ~ints:[| 99; 99 |] ~bools:[| false |] in
  let _ = Tape.finish tape in
  let a4, _, _ = v4 in
  check "clamped to hi" (a4 = 100L);

  (* Truncated input marks an overrun. *)
  let truncated = Array.sub out1.Tape.choices 0 2 in
  Tape.start_replay tape truncated;
  let _ = generate tape ~ints:[| 3; 3 |] ~bools:[| true |] in
  let out5 = Tape.finish tape in
  check "truncation flagged as overrun" out5.Tape.overrun;

  (* Serialization round-trips, including negative ints, floats with
     odd payloads, bools, and markers. *)
  let sample =
    [| Tape.Integer { value = -42L; lo = Int64.min_int; hi = Int64.max_int }
     ; Tape.Float { value = 2.5; lo = 0.; hi = 10. }
     ; Tape.Bool true
     ; Tape.Marker
     ; Tape.Bool false
    |]
  in
  let bytes = Tape.serialize sample in
  (match Tape.deserialize bytes with
  | Some back ->
    check "serialize round-trips" (Tape.equal_choices sample back);
    check "same length" (Array.length back = Array.length sample)
  | None -> failwith "FAILED: deserialize returned None");
  (* Cutting mid-record is rejected; cutting at a record boundary
     yields a valid shorter tape by design (prefix tolerance). *)
  check "truncated input rejected"
    (Option.is_none (Tape.deserialize (String.sub bytes 0 (String.length bytes - 1))));
  check "bad version rejected"
    (Option.is_none (Tape.deserialize ("\002" ^ String.sub bytes 1 (String.length bytes - 1))));
  (* A v2 count may be large even when the payload is already exhausted.
     Reject at the first absent record rather than looping to the declared
     count.  0x0fff_ffff is the largest accepted count. *)
  let huge_truncated_v2 =
    "\002\255\255\255\015\000\000\000\000"
  in
  check "huge truncated v2 input is rejected promptly"
    (Option.is_none (Tape.deserialize_image huge_truncated_v2));
  let noncanonical streams : Tape.image = { main = [||]; streams } in
  check "v2 root-keyed sub-stream is rejected"
    (Option.is_none
       (Tape.deserialize_image
          (Tape.serialize_image
             (noncanonical [| Tape.root, [| Tape.Bool true |] |]))));
  let duplicate_key = [ Tape.Split 0 ] in
  check "v2 duplicate sub-stream keys are rejected"
    (Option.is_none
       (Tape.deserialize_image
          (Tape.serialize_image
             (noncanonical
                [| duplicate_key, [| Tape.Bool true |]
                 ; duplicate_key, [| Tape.Bool false |]
                |]))));
  check "v2 out-of-order sub-stream keys are rejected"
    (Option.is_none
       (Tape.deserialize_image
          (Tape.serialize_image
             (noncanonical
                [| [ Tape.Split 1 ], [| Tape.Bool true |]
                 ; [ Tape.Split 0 ], [| Tape.Bool false |]
                |]))));

  (* A kind mismatch consumes the offending input entry and realigns,
     instead of freezing the position and abandoning the rest. *)
  Tape.start_replay tape
    [| Tape.Integer { value = 9L; lo = 0L; hi = 10L }; Tape.Bool true |];
  let b = Tape.draw_bool tape ~sample:(fun () -> false) in
  check "mismatch skips to the matching entry" (b = true);
  let _ = Tape.finish tape in

  (* Full-range distances do not overflow the ordering: 1 is closer to
     the target than Int64.min_int is. *)
  let full lo hi v = [| Tape.Integer { value = v; lo; hi } |] in
  check "min_int is not spuriously minimal"
    (Tape.compare_shortlex
       (full Int64.min_int Int64.max_int 1L)
       (full Int64.min_int Int64.max_int Int64.min_int)
     < 0);

  (* Shortlex prefers values closer to zero at equal length. *)
  let small = [| Tape.Integer { value = 1L; lo = 0L; hi = 100L } |] in
  let big = [| Tape.Integer { value = 90L; lo = 0L; hi = 100L } |] in
  check "closer to target is smaller" (Tape.compare_shortlex small big < 0);

  print_endline "test_tape: all passed"

let check name cond = if not cond then failwith ("FAILED: " ^ name)

(* A tiny deterministic "generator": draws an int in [0,100], a bool,
   and if the bool is true another int in [0,10]. *)
let generate tape ~ints ~bools =
  let next_int = ref 0 and next_bool = ref 0 in
  let sample_int arr r =
    let v = arr.(!r mod Array.length arr) in
    incr r;
    Int64.of_int v
  in
  let a = Tape.draw_int tape ~lo:0L ~hi:100L ~sample:(fun () -> sample_int ints next_int) in
  let b = Tape.draw_bool tape ~sample:(fun () -> let v = bools.(!next_bool mod Array.length bools) in incr next_bool; v) in
  let c =
    if b then Tape.draw_int tape ~lo:0L ~hi:10L ~sample:(fun () -> sample_int ints next_int)
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
  check "replay re-records identically"
    (Tape.compare_shortlex out1.Tape.choices out2.Tape.choices = 0);

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

  (* Shortlex prefers values closer to zero at equal length. *)
  let small = [| Tape.Integer { value = 1L; lo = 0L; hi = 100L } |] in
  let big = [| Tape.Integer { value = 90L; lo = 0L; hi = 100L } |] in
  check "closer to target is smaller" (Tape.compare_shortlex small big < 0);

  print_endline "all tape tests passed"

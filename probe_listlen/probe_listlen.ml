(* Why list-of-string shrinking stalls: the encoding is ANTI-MONOTONE.

   A tape shrinker rests on one assumption -- that a shortlex-smaller
   tape decodes to a smaller value. base_quickcheck's list encoding
   breaks it, and this probe measures the break rather than arguing it.

   THE SYMPTOM. Same property, seed, size and budget; only the element
   generator differs:

     G.list (G.int_uniform_inclusive 0 1000)  ->  length 10, correct
     G.list G.string                          ->  length 30, never moves

   The property is [List.length l < 10], so the answer is exactly 10.
   The string case reports converged = true, and a hundredfold budget
   changes nothing.

   THE MECHANISM. A list length is drawn by Log_uniform.int, which is
   two choices where the second's BOUNDS depend on the first
   (sr_real.ml:331). In the stuck tape those are

     0  Integer 5  [0,5]     <- bit-size
     1  Integer 30 [16,30]   <- length, domain is a function of choice 0

   Lowering choice 0 does shorten the list. It also makes the tape
   LONGER, because [sizes] (generator.ml:196) computes

     let remaining = size - (len - min_length) in

   and distributes [remaining] over the elements. Freed length is
   redistributed INTO the elements, so a shorter list has bigger ones.
   Measured on the stuck tape:

     bits  list length  re-recorded tape  overrun  chars
     5     30           206               false    14
     4     15           253               true     24
     3     7            235               true     23
     2     3            270               true     29

   Every shortening overruns the recorded tape and grows it. The
   shrinker is right to reject these -- an overrun proposal truncated,
   so its verdict is not trustworthy, and a longer tape is shortlex
   worse anyway. There is no bug in the shrinker here.

   AND THE COMBINED MOVE DOES NOT RESCUE IT. The obvious repair is to
   lower the length and trivialise everything after it in one proposal.
   That is worse still, because the bookkeeping draws are anti-monotone
   too -- setting them to their shortlex target produces MORE content:

     bits  length  tape  overrun  chars
     5     30      230   true     17     (vs 14 untouched)
     4     15      235   true     20
     3     7       239   true     22
     2     3       273   true     29

   CONCLUSION. This is not fixable in the shrinker, and it is not about
   strings. It is the same class of defect as
   proposals/base_quickcheck-non_uniform.patch -- a generator encoding
   that a replay-based reducer cannot work with -- and a bigger one.
   G.list G.int is unaffected only because int_uniform_inclusive ignores
   ~size, so there is nothing to redistribute.

   The fix belongs in base_quickcheck's [sizes]: element sizes should be
   drawn per element, so lowering the length deletes elements and leaves
   the others alone, instead of being computed from a shared budget that
   grows as the length falls. That is wave-2 work (see WAVE-2.md). *)
open! Base

module G = Base_quickcheck.Generator

let replay_with_flags gen img ~size =
  let tape = Tape.create () in
  Tape.start_replay_image tape img;
  let random =
    Splittable_random.For_tape.attach (Splittable_random.of_int 0x7ea9e) tape
  in
  let value = Base_quickcheck.Generator.generate gen ~size ~random in
  let out = Tape.finish tape in
  (value, out)

let target = function
  | Tape.Integer { lo; hi; _ } ->
    Tape.Integer { value = Tape.clamp_int64 0L ~lo ~hi; lo; hi }
  | Tape.Float { lo; hi; _ } ->
    Tape.Float { value = Tape.clamp_float 0. ~lo ~hi; lo; hi }
  | Tape.Bool _ -> Tape.Bool false
  | Tape.Marker -> Tape.Marker

let case name gen show =
  match
    Tape_engine.run gen
      ~test:(fun l -> List.length l < 10)
      ~seed:7 ~count:400 ~size:30 ~budget:50_000 ~max_shrinks:5_000
  with
  | Tape_engine.Passed _ -> Stdio.printf "  %-24s no failure found\n" name
  | Tape_engine.Failed { minimal; image; attempts; converged; _ } ->
    Stdio.printf "  %-24s len %-4d tape %-4d attempts %-6d converged %-5b %s\n"
      name (List.length minimal)
      (Array.length image.Tape.main)
      attempts converged (show minimal)

let () =
  Stdio.printf
    "fails iff length >= 10, so the answer is a list of exactly 10\n\n";
  case "int list, size 30"
    (G.list (G.int_uniform_inclusive 0 1000))
    (fun l -> Printf.sprintf "%d ints" (List.length l));
  case "string list, size 30" (G.list G.string) (fun l ->
    Printf.sprintf "%d chars" (List.sum (module Int) l ~f:String.length));

  match
    Tape_engine.run (G.list G.string)
      ~test:(fun l -> List.length l < 10)
      ~seed:7 ~count:400 ~size:30 ~budget:50_000
  with
  | Tape_engine.Passed _ -> ()
  | Tape_engine.Failed { image; _ } ->
    let show_row ~trivialise bits =
      let edited = Array.copy image.Tape.main in
      (match edited.(0) with
       | Tape.Integer { lo; hi; _ } ->
         edited.(0) <- Tape.Integer { value = Int64.of_int bits; lo; hi }
       | _ -> ());
      if trivialise then
        for i = 2 to Array.length edited - 1 do
          edited.(i) <- target edited.(i)
        done;
      let img = Tape.image_of_main edited in
      let l, out = replay_with_flags (G.list G.string) img ~size:30 in
      Stdio.printf "    %-5d %-7d %-6d %-8b %d\n" bits (List.length l)
        (Array.length out.Tape.image.Tape.main)
        out.Tape.overrun
        (List.sum (module Int) l ~f:String.length)
    in
    Stdio.printf
      "\n  lowering the length bit-size on the stuck tape:\n\
      \    bits  length  tape   overrun  chars\n";
    List.iter [ 5; 4; 3; 2 ] ~f:(show_row ~trivialise:false);
    Stdio.printf
      "\n  the same, also trivialising everything after the length:\n\
      \    bits  length  tape   overrun  chars\n";
    List.iter [ 5; 4; 3; 2 ] ~f:(show_row ~trivialise:true);
    Stdio.printf
      "\n  shortening the list LENGTHENS the tape and grows the content:\n\
      \  freed size is redistributed into the elements by [sizes].\n"

(* Laws a GENERATOR-AS-DECODER must satisfy for the shrinker's search
   to mean anything, plus the accounting invariants that past issues
   broke.

   THE DECODER LAW is the one worth having. Shrinking edits a tape and
   re-runs the generator on it; the generator is therefore not just a
   sampler but the DECODER that says what a tape edit means. Every pass
   assumes that moving choices toward their target does not make the
   re-recorded tape LONGER. base_quickcheck's `sizes` breaks it: it
   spends a running size budget, so zeroing the sizes makes the budget
   last longer, more elements draw, and the all-targets image comes back
   bigger than the one it was derived from. Measured on the
   wave2/monotone-list-sizes branch: all-targets 82 choices against a
   typical 62, which silently disables the pre-loop trivialization
   because the "trivial" image is not shortlex-smaller.

   Hypothesis avoids this by construction -- collections are drawn
   through continuation booleans whose target is "stop", so all-targets
   is always the SHORTEST recording (conjecture/utils.py, `many`), and
   they rejected QuickCheck-style size distribution in 2015 for the
   related reason that nesting multiplies it.

   This law would have caught that class automatically. It is stated
   over the generators master actually ships. *)
open! Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name cond detail =
  if not cond then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-46s %s\n" name detail
  end
  else Stdio.printf "  ok   %-46s %s\n" name detail

let trivialize (img : Tape.image) : Tape.image =
  { main = Array.map img.Tape.main ~f:Tape.Domain.target
  ; streams =
      Array.map img.Tape.streams ~f:(fun (k, a) ->
        (k, Array.map a ~f:Tape.Domain.target))
  }

(* Record one generation, then replay the all-targets version of what
   was recorded and see how long the re-recording is. *)
let target_not_longer (type a) ~name (gen : a G.t) ~size =
  let worst = ref 0 in
  let checked = ref 0 in
  for seed = 0 to 199 do
    let tape = Tape.create () in
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
    in
    let (_ : a) = G.generate gen ~size ~random in
    let out = Tape.finish tape in
    let original = Tape.image_size out.Tape.image in
    let t2 = Tape.create () in
    Tape.start_replay_image t2 (trivialize out.Tape.image);
    let random2 =
      Splittable_random.For_tape.attach (Splittable_random.of_int 0x7ea9e) t2
    in
    let (_ : a) = G.generate gen ~size ~random:random2 in
    let out2 = Tape.finish t2 in
    Int.incr checked;
    let grew = Tape.image_size out2.Tape.image - original in
    if grew > !worst then worst := grew
  done;
  check (Printf.sprintf "target-is-not-longer: %s" name) (!worst <= 0)
    (Printf.sprintf "worst growth %+d choices over %d seeds" !worst !checked)

let () =
  Stdio.printf "encoding laws\n\n";
  target_not_longer ~name:"list of ints" (G.list (G.int_inclusive 0 100)) ~size:20;
  target_not_longer ~name:"list of lists"
    (G.list (G.list (G.int_inclusive 0 100))) ~size:15;
  target_not_longer ~name:"list of strings" (G.list G.string) ~size:15;
  target_not_longer ~name:"recursive (max_leaves)"
    (G.recursive_with_max_leaves ~max_leaves:12
       (G.map (G.int_inclusive 0 5) ~f:(fun i -> [ i ]))
       ~f:(fun self -> G.map (G.both self self) ~f:(fun (a, b) -> a @ b)))
    ~size:12;
  target_not_longer ~name:"structural list"
    (G.list_structural (G.int_inclusive 0 100)) ~size:20;
  (* The shape that actually exercises a size BUDGET: more elements
     than the ambient size, so the budget is exhausted partway and the
     encoding has to decide what the remaining elements do. A law
     stated only over short lists is vacuous for this defect -- the
     first draft of this file passed on the branch that has it. *)
  target_not_longer ~name:"fixed-length list, len > size"
    (G.list_with_length (G.int_uniform_inclusive 0 1000) ~length:40) ~size:20;
  target_not_longer ~name:"fixed-length list of lists, len > size"
    (G.list_with_length (G.list (G.int_inclusive 0 100)) ~length:30) ~size:10;
  if !failures > 0 then begin
    Stdio.printf "\ntest_encoding_laws: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_encoding_laws: all laws held\n"

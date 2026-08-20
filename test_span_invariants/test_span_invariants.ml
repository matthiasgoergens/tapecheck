(* Properties over the invariants that the span-consuming shrink passes
   ASSUME. Written after a cross-model review found reorder_spans
   bounds-checking its child spans but not its parent, whose interval
   is fed straight to [Array.sub]; an out-of-range parent would raise
   outside [attempt] and abort the whole shrink. The guard went in;
   these pin the invariants behind it, so a break fails here rather
   than as a crash in a pass that trusted them.

   Properties over GENERATION: spans are recorded by the tape, so these
   are statements about what [Tape.finish] hands out, and every
   consumer inherits them.

   ONE OF THESE FOUND SOMETHING. The first draft asserted that a span
   of depth d > 0 has a containing span of depth d - 1. It fails, 1 per
   image, and the code is right: [depth] is [List.length open_spans] at
   close, which counts spans that are later FILTERED OUT --
   [recursive_with_max_leaves] wraps each layer in a
   [discard_on_exception] attempt span that is discarded on success. So
   a retained span can sit at depth d with no retained parent at d - 1.
   The consequence for reorder_spans is a false negative, not a
   correctness bug: "direct child = parent.depth + 1" can MISS children
   separated from their parent by an unretained span, so the pass
   silently does less than it looks like it does. The property below is
   the true one -- containment implies strictly smaller depth. *)
open! Base
module G = Base_quickcheck.Generator

let failures = ref 0

let check name cond detail =
  if not cond then begin
    Int.incr failures;
    Stdio.printf "  FAIL %-50s %s\n" name detail
  end
  else Stdio.printf "  ok   %-50s %s\n" name detail

let subject =
  G.both
    (G.with_reorderable_span
       (G.both
          (G.with_reorderable_span (G.list (G.int_inclusive 0 20)))
          (G.with_reorderable_span (G.list (G.int_inclusive 0 20)))))
    (G.recursive_with_max_leaves ~max_leaves:12
       (G.map (G.int_inclusive 0 5) ~f:(fun i -> [ i ]))
       ~f:(fun self -> G.map (G.both self self) ~f:(fun (a, b) -> a @ b)))

let stream_lengths (out : Tape.output) =
  (Tape.root, Array.length out.Tape.image.Tape.main)
  :: (Array.to_list out.Tape.image.Tape.streams
      |> List.map ~f:(fun (k, arr) -> (k, Array.length arr)))

let length_of lengths key =
  List.find_map lengths ~f:(fun (k, n) ->
    if Tape.compare_key k key = 0 then Some n else None)

let () =
  Stdio.printf "span invariants\n\n";
  let bounds = ref 0 and orphan = ref 0 and depth_mono = ref 0 in
  let overlap = ref 0 and spans_seen = ref 0 and images = ref 0 in
  for seed = 0 to 299 do
    let tape = Tape.create () in
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
    in
    let (_ : (int list * int list) * int list) =
      G.generate subject ~size:12 ~random
    in
    let out = Tape.finish tape in
    Int.incr images;
    let lengths = stream_lengths out in
    let spans = Array.to_list out.Tape.spans in
    spans_seen := !spans_seen + List.length spans;
    List.iter spans ~f:(fun sp ->
      match length_of lengths sp.Tape.stream with
      | None -> Int.incr orphan
      | Some n ->
        if not
             (sp.Tape.start >= 0 && sp.Tape.stop >= sp.Tape.start
              && sp.Tape.stop <= n)
        then Int.incr bounds);
    let rec pairs = function
      | [] -> ()
      | sp :: rest ->
        List.iter rest ~f:(fun other ->
          if Tape.compare_key sp.Tape.stream other.Tape.stream = 0 then begin
            let disjoint =
              sp.Tape.stop <= other.Tape.start
              || other.Tape.stop <= sp.Tape.start
            in
            let sp_in_other =
              other.Tape.start <= sp.Tape.start && sp.Tape.stop <= other.Tape.stop
            in
            let other_in_sp =
              sp.Tape.start <= other.Tape.start && other.Tape.stop <= sp.Tape.stop
            in
            if not (disjoint || sp_in_other || other_in_sp) then Int.incr overlap;
            (* Strict containment must mean strictly greater depth. This
               is what makes depth usable for parent/child selection at
               all, given that it counts unretained spans too. *)
            if sp_in_other && not (phys_equal sp other) then begin
              let strictly_inside =
                other.Tape.start < sp.Tape.start || sp.Tape.stop < other.Tape.stop
              in
              if strictly_inside && not (sp.Tape.depth > other.Tape.depth) then
                Int.incr depth_mono
            end
          end);
        pairs rest
    in
    pairs spans
  done;
  check "every span lies within the stream it names" (!bounds = 0)
    (Printf.sprintf "%d out of bounds" !bounds);
  check "no span names a stream absent from the image" (!orphan = 0)
    (Printf.sprintf "%d orphans" !orphan);
  check "same-stream spans nest, never partially overlap" (!overlap = 0)
    (Printf.sprintf "%d partial overlaps" !overlap);
  check "strict containment implies strictly greater depth" (!depth_mono = 0)
    (Printf.sprintf "%d violations" !depth_mono);
  check "the properties were not vacuous" (!spans_seen > 100)
    (Printf.sprintf "%d spans over %d images" !spans_seen !images);
  (* Laws of the rearrangement. It returns an index MAPPING rather
     than an array, which buys two things: the operation is a
     permutation by construction (the array is built by indexing the
     input, so no arithmetic slip can invent or drop a choice), and the
     mapping is a witness a test can check directly.

     That witness is what makes the strong property expressible. A
     multiset comparison of the output only says the same values are
     present -- a bug that also shuffled the GAPS would satisfy it.
     With the mapping we can assert the real contract: it is a
     bijection, it is the identity everywhere outside the children, and
     the children's contents move as whole blocks. *)
  let bij_bad = ref 0 and outside_bad = ref 0 and id_bad = ref 0 in
  let block_bad = ref 0 and precond_bad = ref 0 and cases = ref 0 in
  for seed = 0 to 199 do
    let tape = Tape.create () in
    Tape.start_recording tape;
    let random =
      Splittable_random.For_tape.attach (Splittable_random.of_int seed) tape
    in
    let (_ : (int list * int list) * int list) =
      G.generate subject ~size:12 ~random
    in
    let main = (Tape.finish tape).Tape.image.Tape.main in
    let n = Array.length main in
    if n >= 8 then begin
      let q = n / 4 in
      let children = [ (q, 2 * q); (2 * q, 3 * q) ] in
      Int.incr cases;
      (* Identity order must give the identity mapping. *)
      (match
         Tape_engine.Diagnostics.reassemble_permutation ~n ~parent_start:0 ~parent_stop:n
           ~children ~order:[ 0; 1 ]
       with
       | None -> Int.incr id_bad
       | Some m ->
         if not (Array.for_alli m ~f:(fun i j -> i = j)) then Int.incr id_bad);
      (* Swapped order: a bijection, identity outside the children, and
         each child's content carried as a contiguous block. *)
      (match
         Tape_engine.Diagnostics.reassemble_permutation ~n ~parent_start:0 ~parent_stop:n
           ~children ~order:[ 1; 0 ]
       with
       | None -> Int.incr bij_bad
       | Some m ->
         let seen = Array.create ~len:n false in
         Array.iter m ~f:(fun j ->
           if j < 0 || j >= n || seen.(j) then Int.incr bij_bad
           else seen.(j) <- true);
         if Array.length m <> n then Int.incr bij_bad;
         Array.iteri m ~f:(fun i j ->
           let inside_children =
             (i >= q && i < 3 * q) || (j >= q && j < 3 * q)
           in
           if (not inside_children) && i <> j then Int.incr outside_bad);
         (* The second child's block lands where the first began. *)
         let len2 = 3 * q - (2 * q) in
         for d = 0 to len2 - 1 do
           if m.(q + d) <> (2 * q) + d then Int.incr block_bad
         done);
      (match
         Tape_engine.Diagnostics.reassemble_permutation ~n ~parent_start:0 ~parent_stop:n
           ~children:[ (q, 3 * q); (2 * q, 3 * q) ] ~order:[ 0; 1 ]
       with
       | None -> ()
       | Some _ -> Int.incr precond_bad);
      (match
         Tape_engine.Diagnostics.reassemble_permutation ~n ~parent_start:0
           ~parent_stop:(n + 5) ~children ~order:[ 0; 1 ]
       with
       | None -> ()
       | Some _ -> Int.incr precond_bad);
      match
        Tape_engine.Diagnostics.reassemble_permutation ~n ~parent_start:0 ~parent_stop:n
          ~children ~order:[ 0; 0 ]
      with
      | None -> ()
      | Some _ -> Int.incr precond_bad
    end
  done;
  check "identity order gives the identity mapping" (!id_bad = 0)
    (Printf.sprintf "%d failed" !id_bad);
  check "the mapping is a bijection" (!bij_bad = 0)
    (Printf.sprintf "%d failed" !bij_bad);
  check "identity everywhere outside the children" (!outside_bad = 0)
    (Printf.sprintf "%d positions moved" !outside_bad);
  check "each child moves as a contiguous block" (!block_bad = 0)
    (Printf.sprintf "%d positions wrong" !block_bad);
  check "rejects overlapping, out-of-range, or non-permuted input"
    (!precond_bad = 0) (Printf.sprintf "%d accepted" !precond_bad);
  check "  ^ were not vacuous" (!cases > 100)
    (Printf.sprintf "%d subjects" !cases);
  if !failures > 0 then begin
    Stdio.printf "\ntest_span_invariants: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_span_invariants: all properties held\n"

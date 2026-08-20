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
  (* Laws of the reconstruction, stateable only because it was
     extracted from reorder_spans's mutable cursor. The design-pressure
     argument in miniature: the code with no property to state is where
     the mutation experiment found a bug, and the property appeared as
     soon as the operation became a function. *)
  let perm_bad = ref 0 and id_bad = ref 0 and len_bad = ref 0 in
  let precond_bad = ref 0 and cases = ref 0 in
  let multiset a = List.sort (Array.to_list a) ~compare:Tape.compare_choice in
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
      let slices =
        List.map children ~f:(fun (a, b) -> Array.sub main ~pos:a ~len:(b - a))
      in
      Int.incr cases;
      (match
         Tape_engine.reassemble_interval main ~parent_start:0 ~parent_stop:n
           ~children ~slices
       with
       | None -> Int.incr id_bad
       | Some out -> if not (Tape.equal_choices out main) then Int.incr id_bad);
      (match
         Tape_engine.reassemble_interval main ~parent_start:0 ~parent_stop:n
           ~children ~slices:(List.rev slices)
       with
       | None -> Int.incr perm_bad
       | Some out ->
         if Array.length out <> n then Int.incr len_bad;
         if
           not
             (List.equal
                (fun a b -> Tape.compare_choice a b = 0)
                (multiset out) (multiset main))
         then Int.incr perm_bad);
      (match
         Tape_engine.reassemble_interval main ~parent_start:0 ~parent_stop:n
           ~children:[ (q, 3 * q); (2 * q, 3 * q) ] ~slices
       with
       | None -> ()
       | Some _ -> Int.incr precond_bad);
      match
        Tape_engine.reassemble_interval main ~parent_start:0
          ~parent_stop:(n + 5) ~children ~slices
      with
      | None -> ()
      | Some _ -> Int.incr precond_bad
    end
  done;
  check "reassembly with each child's own slice is the identity" (!id_bad = 0)
    (Printf.sprintf "%d failed" !id_bad);
  check "reassembly preserves length" (!len_bad = 0)
    (Printf.sprintf "%d failed" !len_bad);
  check "reassembly is a permutation of the original" (!perm_bad = 0)
    (Printf.sprintf "%d failed" !perm_bad);
  check "reassembly rejects overlapping/out-of-range intervals"
    (!precond_bad = 0) (Printf.sprintf "%d accepted" !precond_bad);
  check "  ^ were not vacuous" (!cases > 100)
    (Printf.sprintf "%d subjects" !cases);
  if !failures > 0 then begin
    Stdio.printf "\ntest_span_invariants: %d FAILED\n" !failures;
    Stdlib.exit 1
  end
  else Stdio.printf "\ntest_span_invariants: all properties held\n"

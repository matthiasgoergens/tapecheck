(* Is the reformulated non_uniform distribution-identical? The claim
   that makes it proposable upstream, so it needs measuring rather than
   asserting. Both forms should give: 5% exactly lo, 5% exactly hi, 90%
   from the underlying generator. *)
open Base
module G = Base_quickcheck.Generator

let n = 400_000

let () =
  let lo_hits = ref 0 and hi_hits = ref 0 and other = ref 0 in
  let neg = ref 0 in
  let buckets = Array.create ~len:64 0 in
  let random = Splittable_random.of_int 12345 in
  for _ = 1 to n do
    let v = Base_quickcheck.Generator.generate G.int ~size:30 ~random in
    if v < 0 then Int.incr neg;
    let m = if v < 0 then lnot v else v in
    if m = 0 then Int.incr lo_hits
    else if m = Int.max_value then Int.incr hi_hits
    else Int.incr other;
    let b = if m = 0 then 0 else Int.floor_log2 m + 1 in
    buckets.(Int.min 63 b) <- buckets.(Int.min 63 b) + 1
  done;
  let pct k = 100. *. Float.of_int k /. Float.of_int n in
  Stdio.printf "G.int over %d draws\n" n;
  Stdio.printf "  magnitude = 0          %7d  %6.3f%%  (expect ~5%%)\n" !lo_hits (pct !lo_hits);
  Stdio.printf "  magnitude = max_value  %7d  %6.3f%%  (expect ~5%%)\n" !hi_hits (pct !hi_hits);
  Stdio.printf "  other                  %7d  %6.3f%%  (expect ~90%%)\n" !other (pct !other);
  Stdio.printf "  negative               %7d  %6.3f%%  (expect ~50%%)\n" !neg (pct !neg);
  Stdio.printf "\n  magnitude bit-length histogram (bucket: count):\n   ";
  Array.iteri buckets ~f:(fun i c -> if c > 0 then Stdio.printf " %d:%d" i c);
  Stdio.printf "\n"

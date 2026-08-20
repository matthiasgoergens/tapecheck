external bool : Sr_real.t -> bool = "tapecheck_fast_bool" [@@noalloc]

external int_unlabelled
  :  Sr_real.t
  -> int
  -> int
  -> int
  = "tapecheck_fast_int"
[@@noalloc]

external float_unlabelled
  :  Sr_real.t
  -> (float[@unboxed])
  -> (float[@unboxed])
  -> (float[@unboxed])
  = "tapecheck_fast_float_byte" "tapecheck_fast_float"
[@@noalloc]

let int state ~lo ~hi = int_unlabelled state lo hi
let float state ~lo ~hi = float_unlabelled state lo hi

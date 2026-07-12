open! Base

(* Before the refactor, the closure below could not be portable: the
   shim consulted a global mutable ref (see
   blog/materials/mode-error-before.txt for the compiler's rejection).
   With the tape carried inside the random state, an entire shrink
   attempt is self-contained, and the mode checker agrees. *)
let probe : (unit -> unit) Modes.Portable.t =
  { portable =
      (fun () ->
        let tape = Tape.create () in
        Tape.start_recording tape;
        let random =
          Splittable_random.For_tape.attach (Splittable_random.of_int 1) tape
        in
        let (_ : int) = Splittable_random.int random ~lo:0 ~hi:10 in
        let (_ : Tape.output) = Tape.finish tape in
        ())
  }

let () = (Modes.Portable.unwrap probe) ()

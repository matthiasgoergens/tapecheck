(** [Trampoline] is a monad meant to help with "stack overflow" issues in js_of_ocaml
    programs.

    JSOO does not have tail call optimization, so if you write a deeply recursive
    function, you may run into stack overflow issues.

    If a function like:

    {[
      let some_function x =
        let rec f x =
          let a = f (x - 1) in
          let b = f (x - 2) in
          some_reduce a b
        in
        f x
      ;;
    ]}

    stack overflows, you can re-write it with trampoline with:

    {[
      let some_function x =
        let rec f x =
          let%bind.Trampoline a = f (x - 1) in
          let%bind.Trampoline b = f (x - 2) in
          Trampoline.return (some_reduce a b)
        in
        Trampoline.run (f x)
      ;;
    ]} *)

open! Core

type 'a t

val lazy_ : 'a t Lazy.t -> 'a t
val run : 'a t -> 'a
val return : 'a -> 'a t
val all_map : ('k, 'v t, 'cmp) Map.t -> ('k, 'v, 'cmp) Map.t t
val all : 'a t list -> 'a list t
val map : 'a t -> f:('a -> 'b) -> 'b t
val all_nonempty_list : 'a t Nonempty_list.t -> 'a Nonempty_list.t t

(*_ this is a stripped-down let syntax intended to prevent you from using [let%map] and
    [and] in the syntax. *)
module Let_syntax : sig
  val return : 'a -> 'a t

  module Let_syntax : sig
    val return : 'a -> 'a t
    val bind : 'a t -> f:('a -> 'b t) -> 'b t
    val map : 'a t -> f:('a -> 'b) -> 'b t
    val both : 'a t -> 'b t -> ('a * 'b) t
  end
end

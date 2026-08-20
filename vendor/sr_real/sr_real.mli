(** A splittable pseudo-random number generator (SPRNG) functions like a PRNG in that it
    can be used as a stream of random values; it can also be "split" to produce a second,
    independent stream of random values.

    This module implements a splittable pseudo-random number generator that sacrifices
    cryptographic-quality randomness in favor of performance.

    The primary difference between [Splittable_random] and {!Random} is the [split]
    operation for generating new pseudo-random states.  While it is easy to simulate
    [split] using [Random], the result has undesirable statistical properties; the
    new state does not behave independently of the original.  It is better to switch to
    [Splittable_random] if you need an operation like [split], as this module has
    been implemented with the statistical properties of splitting in mind.  For most other
    purposes, [Random] is likely a better choice, as its implementation passes all Diehard
    tests, while [Splittable_random] fails some Diehard tests.
*)

open! Base

type t

(** Extensible structural labels for property-testing engines. *)
type span_label = ..

(** Create a new [t] seeded from the given random state. This allows nondeterministic
    initialization, for example in the case that the input state was created using
    [Random.make_self_init].

    Constructors like [create] and [of_int] should be called once at the start of a
    randomized computation and the resulting state should be threaded through.
    Repeatedly creating splittable random states from seeds in the middle of computation
    can defeat the SPRNG's splittable properties. *)
val create : Random.State.t -> t

(** Create a new [t] that will return identical results to any other [t] created with
    that integer. *)
val of_int : int -> t

(** [perturb t salt] adds the entropy of [salt] to [t]. *)
val perturb : t -> int -> unit

(** Create a copy of [t] that will return the same random samples as [t]. *)
val copy : t -> t

(** [split t] produces a new state that behaves deterministically (i.e. only depending
    on the state of [t]), but pseudo-independently from [t]. This operation mutates
    [t], i.e., [t] will return different values than if this hadn't been called. *)
val split : t -> t

(** Interception hooks for property-testing engines that need to observe,
    record, or replay the stream of bounded draws (for example, choice-tape
    shrinkers in the style of Python Hypothesis's Conjecture engine).

    A state carrying hooks consults them on each draw, passing the default
    sampler so the hook can fall back to ordinary sampling; states without
    hooks (the default, and everything this module constructs itself) behave
    exactly as before, at the cost of one branch per draw. All bounded
    integer draws ([int], [int32], [int63], [nativeint], and [Log_uniform])
    delegate to [int64], so the [int64] hook observes every one of them with
    its bounds.

    Seam v2: [on_split] returns the hooks to install on the freshly split
    state ([None] leaves it hook-free), and [on_perturb] receives the salt
    and may return replacement hooks for this state ([None] keeps the
    current hooks). Engines use these to key split-off streams, so that
    randomly generated functions become observable and shrinkable; see
    design/stream-keyed-tapes.md.

    This is an experimental, unreleased seam. [Intercept.t] is abstract and
    [create] supplies delegating defaults, so later optional capabilities can
    be added without exposing or extending a record constructed by clients. *)
module Intercept : sig
  type state := t

  type t

  (** [create ()] constructs a delegating observer: every primitive calls its
      supplied [default], structural callbacks do nothing, split children are
      unobserved, and perturbation keeps the current observer. Override only
      the capabilities an engine implements. Keeping [t] abstract and the
      callbacks optional lets this experimental seam grow without breaking
      every observer construction. *)
  val create
    :  ?int64:
         (state
          -> lo:int64
          -> hi:int64
          -> default:(state -> lo:int64 -> hi:int64 -> int64)
          -> int64)
    -> ?float:
         (state
          -> lo:float
          -> hi:float
          -> default:(state -> lo:float -> hi:float -> float)
          -> float)
    -> ?unit_float:(state -> default:(state -> float) -> float)
    -> ?bool:(state -> default:(state -> bool) -> bool)
    -> ?bool_with_probability:
         (state
          -> probability:float
          -> forced:bool option
          -> default:(state -> probability:float -> bool)
          -> bool)
    -> ?on_span_start:
         (span_label
          -> deletable:bool
          -> discardable:bool
          -> descendable:bool
          -> reorderable:bool
          -> unit)
    -> ?on_span_stop:
         (deletable:bool
          -> discardable:bool
          -> descendable:bool
          -> reorderable:bool
          -> discarded:bool
          -> unit
          -> unit)
    -> ?on_split:(unit -> t option)
    -> ?on_perturb:(int -> t option)
    -> unit
    -> t

  (** [is_active state] supports a whole-computation fast/observed split.
      Performance-sensitive generated code should test this once and retain a
      direct primitive path when false, rather than paying [run_*] dispatch on
      every draw. *)
  val is_active : state -> bool

  (** Backend-facing dispatch for pointwise-equivalent optimized samplers.
      With no interceptor these functions perform one hook-presence branch and
      call [default]. With hooks attached, the bounded draw is observed exactly
      like the corresponding top-level sampler. This lets staged or foreign
      randomness implementations keep their fast inactive path without
      silently bypassing a property-testing engine. *)
  val run_bool : state -> default:(state -> bool) -> bool

  val run_int
    :  state
    -> lo:int
    -> hi:int
    -> default:(state -> lo:int -> hi:int -> int)
    -> int

  val run_int64
    :  state
    -> lo:int64
    -> hi:int64
    -> default:(state -> lo:int64 -> hi:int64 -> int64)
    -> int64

  val run_float
    :  state
    -> lo:float
    -> hi:float
    -> default:(state -> lo:float -> hi:float -> float)
    -> float

  val run_unit_float : state -> default:(state -> float) -> float
end

(** [with_intercept t hooks] returns a snapshot copy of [t] whose draws
    consult [hooks]; [t] itself is unchanged. [copy] preserves hooks;
    [split] calls [on_split] and installs whatever hooks it returns on the
    freshly split state ([None] leaves the split state hook-free);
    [perturb] calls [on_perturb] before mixing in the salt and installs
    whatever hooks it returns ([None] keeps the current hooks). *)
val with_intercept : t -> Intercept.t -> t

module State : sig
  type nonrec t = t

  val create : Random.State.t -> t
  val of_int : int -> t
  val perturb : t -> int -> unit
  val copy : t -> t
  val split : t -> t
end
[@@deprecated
  "[since 2023-10] There is no longer any need to use [Splittable_random.State]. Its \
   definitions are now included directly in [Splittable_random]."]

(** Produces a random, fair boolean. *)
val bool : t -> bool

(** [bool_with_probability t ~probability] is true with the given probability.
    [probability] must be finite and between zero and one, inclusive.  A
    [forced] result and the probability-zero/one cases do not advance [t], but
    are still reported to an interceptor so a replay tree retains the forced
    structural node.  A forced value with zero probability is rejected. *)
val bool_with_probability : ?forced:bool -> t -> probability:float -> bool

(** [with_span t label ~f] notifies an attached observer of a structurally
    related region around [f].  [deletable] declares that removing the whole
    region is meaningful to replay; observational spans leave it false.  With
    no interceptor it calls [f] directly.
    A started span is stopped even if [f] raises.  Observer callbacks must not
    raise; if they do, their exception is propagated.  If both [f] and the
    stop callback raise, [Exn.Finally] preserves both exceptions.
    [discard_on_exception] asks the observer to retain the region only when
    [f] raises, for input consumed by an abandoned generation attempt.
    [descendable] declares that a same-labelled nested region represents a
    value which may replace this one during replay. Deletion and descendant
    replacement capabilities apply only when [f] returns successfully; a
    region which raises is retained solely as discarded input when
    [discard_on_exception] is set. *)
val with_span
  :  ?deletable:bool
  -> ?discard_on_exception:bool
  -> ?descendable:bool
  -> ?reorderable:bool
  -> t
  -> span_label
  -> f:(unit -> 'a)
  -> 'a

(** Produce a random number uniformly distributed in the given inclusive range.  (In the
    case of [float], [hi] may or may not be attainable, depending on rounding.)  *)
val int : t -> lo:int -> hi:int -> int

val int32 : t -> lo:int32 -> hi:int32 -> int32
val int63 : t -> lo:Int63.t -> hi:Int63.t -> Int63.t
val int64 : t -> lo:int64 -> hi:int64 -> int64
val nativeint : t -> lo:nativeint -> hi:nativeint -> nativeint
val float : t -> lo:float -> hi:float -> float

(** [unit_float state = float state ~lo:0. ~hi:1.], but slightly more efficient (and
    right endpoint is exclusive). *)
val unit_float : t -> float

module Log_uniform : sig
  (** Produce a random number in the given inclusive range, where the number of bits in
      the representation is chosen uniformly based on the given range, and then the value
      is chosen uniformly within the range restricted to the chosen bit width. Raises if
      [lo < 0 || hi < lo].

      These functions are useful for choosing numbers that are weighted low within a given
      range. *)
  val int : t -> lo:int -> hi:int -> int

  val int32 : t -> lo:int32 -> hi:int32 -> int32
  val int63 : t -> lo:Int63.t -> hi:Int63.t -> Int63.t
  val int64 : t -> lo:int64 -> hi:int64 -> int64
  val nativeint : t -> lo:nativeint -> hi:nativeint -> nativeint
end

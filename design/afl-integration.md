# Note: AFL and typed choice tapes (post-M6 direction)

AFL's substrate is an untyped byte buffer; when it drives a generator
(crowbar-style), that buffer is an alignment-fragile, type-blind choice
sequence: insertions shift the meaning of every later draw, and a bit
flip in a length prefix reinterprets the remainder. Coverage feedback
compensates but fights the encoding.

Three transfer routes for the tape model:

1. Corpus entries as serialized typed tapes plus an AFL++ custom
   mutator: deserialize, mutate CHOICES (integers within their
   recorded bounds, bool flips, splices at choice boundaries),
   re-serialize. Aligned and in-bounds by construction. Prior art
   validating the idea: Zest/JQF parametric fuzzing (untyped
   proto-tape + coverage), Hypothesis's PrimitiveProvider backends
   (their Antithesis URandomProvider is fuzzer-entropy-in,
   typed-choices-out).
2. Shrinking: afl-tmin is byte-level and poor on structured inputs; a
   tape corpus makes our replay-based shrinker the minimizer, with the
   invariant-preservation guarantee ("Test-Case Reduction via
   Test-Case Generation").
3. Coverage feedback into the engine (HypoFuzz direction): the tape is
   a better genome than bytes for a coverage-guided search.

Compatibility mode requiring no AFL changes: make tape deserialization
total (any byte string clamps into some valid tape), then plain AFL
fuzzes through it; this is Hypothesis's old pre-IR bytestream design,
kept for years for exactly this reason.

Per ecosystem: proptest already has ct1 serialization and could retire
its PassThrough/Recorder RNGs once a cargo-fuzz/AFL++ mutator over ct1
exists. For OCaml, crowbar is the incumbent AFL bridge (untyped,
near-dormant); ocaml-tape plus an AFL++ mutator would be its typed
successor, pitched as "AFL-fuzz your existing base_quickcheck
properties, minimal counterexamples out". Missing piece here: tape
serialization in the OCaml core.

Caveat to measure, not assume: type-aware mutation costs more per
execution than havoc bit-flipping; Zest's result says semantic
validity buys more than throughput loses, but a real integration
should benchmark that.

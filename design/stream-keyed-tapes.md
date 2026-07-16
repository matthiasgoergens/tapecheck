# Stream-keyed tapes: shrinking generated functions

Status: design note, not implemented. Follows the 2026-07-16 discussion
of whether `Generator.fn`'s split-off streams can be brought under tape
control.

## The problem

`Generator.fn dom rng` builds a random function in two steps
(vendor/base_quickcheck/generator.ml):

```ocaml
let fn dom rng =
  create (fun ~size ~random ->
    let random = Splittable_random.split random in
    fun x ->
      let hash = Observer0.observe dom x ~size ~hash:(Hash.alloc ()) in
      let random = Splittable_random.copy random in
      Splittable_random.perturb random (Hash.get_hash_value hash);
      generate rng ~size ~random)
;;
```

At generation time it splits the main stream once. At call time it
copies the split-off state, perturbs the copy with the argument's
observed hash, and generates the result from that. So each distinct
argument reads a deterministic stream keyed by (split state, salt), and
the function is pure within a run.

Under the tape engine today (vendor/splittable_random shim), split-off
states are hook-free: `on_split` records a `Marker` for alignment and
that is all. Consequences:

1. Function results draw fresh randomness, invisible to the tape, so
   generated functions do not shrink. Editing the tape can never
   simplify what `f` returns.
2. The per-call `perturb` inside `fn` never fires `on_perturb` at all:
   it acts on a copy of the hook-free split state. The `on_perturb`
   marker we do record only covers `Generator.perturb` on the main
   hooked stream.
3. Replay is only self-consistent, not stable. During replay, taped
   draws return recorded values without advancing the underlying PRNG,
   so by the time `split` runs, the parent seed differs from recording
   time and the split-off function differs too. Soundness survives
   because every accepted shrink re-runs the test and the final minimal
   is validated in its own replay run (the reported counterexample is
   genuine and reproducible from its tape). But shrink attempts that
   involve generated functions flip a hidden coin, which costs shrink
   quality, and a human reading intermediate attempts sees the
   function's behaviour drift.

Note on prior art: Hypothesis's `functions()` does NOT share this
limitation. It draws lazily from the live choice sequence at call time,
memoised per argument, so function results participate in shrinking.
QuickCheck-style CoArbitrary (and our current shim) is the model that
does not shrink.

## The design: streams as first-class tape citizens

Give every draw a stream key, and make the tape a family of
sub-sequences instead of one sequence.

Stream keys:

- The main stream has key `[]` (root).
- When `split` runs on a hooked state, the parent's hooks allocate the
  child key `parent_key @ [Split n]`, where `n` counts splits recorded
  on that parent so far (0-based ordinal). The child state gets hooks
  carrying that key. The ordinal makes keys deterministic given the
  same sequence of taped events.
- `copy` preserves hooks and key unchanged (it already preserves hooks
  upstream).
- `perturb salt` on a hooked state extends its key: `key @ [Salt salt]`.
  For `fn`, the per-argument copy then draws under
  `split_key @ [Salt hash]`, which is exactly the (split state, salt)
  identity the generator itself uses.

Tape shape:

- `tape = { main : choice sequence; streams : (key, choice sequence) map }`
  with the existing choice type per stream. The current single-sequence
  tape is the `streams = empty` special case.
- Serialization: the existing format for `main`, then length-prefixed
  keyed sections, keys sorted. Bump the version byte; old tapes load as
  main-only (prefix-tolerant, like today).
- Shortlex order: compare `main` first, then streams in sorted key
  order, each by the existing per-choice order; fewer streams beats
  more streams. Total order, so acceptance stays a strict descent.

Recording: a draw on a hooked state appends to the sequence named by
the state's current key. Replay: each stream holds its own cursor;
draws pop from their own stream under the usual kind-match rules.

Realignment: unchanged machinery, applied per stream. A shrink edit
that changes an argument's observed hash moves the salt, so the call
reads a stream key with no recorded entries: those draws fall back to
fresh sampling (the same overrun rule as today), and the orphaned
stream's records die with the next accepted tape (garbage-collect
streams that the accepted replay never touched, the multi-stream
analogue of truncating the unused tail). Freeze/Consume/`Both` apply
within each stream independently.

New shrink moves this unlocks:

- Per-choice passes (lowering, bisection) inside each function stream:
  simplify what `f` returns for the arguments the test actually used.
- Whole-stream deletion: drop a function stream entirely so those calls
  resample fresh; accepted only if still failing and shortlex-smaller,
  which in practice pushes towards functions whose observed behaviour
  is constant.

What this fixes beyond shrinking: replay stability. Function draws come
from the tape, so a replayed attempt evaluates the same function
behaviour for the same arguments, killing the hidden coin-flip in
today's attempts. (The split-off PRNG seed still differs under replay,
but it only feeds unrecorded positions, where fresh randomness is the
intended semantics.)

## Seam revision required upstream

Two changes to the `Intercept` record (the vendored copy can prototype
both without upstream):

1. `on_split : unit -> t option` in place of `unit -> unit`: the
   parent's hook returns the intercept to install on the child state,
   or `None` for today's hook-free child. `split` becomes:
   attach the returned hooks to the freshly built child.
2. `on_perturb : int -> unit` in place of `unit -> unit`: the hook
   needs the salt to extend the stream key. (Today the salt is dropped,
   and the marker only serves main-stream alignment.)

Both are backward-compatible for engines that want the old behaviour
(`on_split = fun () -> None`, ignore the salt). Zero cost when
`intercept = None` is unchanged: the branches are in `split`/`perturb`,
which are not hot paths.

Timing: hold this until ceastlund engages on the base PR
(janestreet/splittable_random#2). If the seam lands, propose this as a
follow-up revision; folding it in now would grow the PR under review.

## Prototype plan (tapecheck, vendored, no upstream dependency)

1. `tape/tape.ml`: add stream keys and the keyed map; keep the
   single-stream API as the root-stream case so existing callers do not
   change. Serialization version bump.
2. `vendor/sr_real`: apply the seam revision (it is our patch already).
3. `vendor/splittable_random` shim: `For_tape.attach` builds hooks
   closing over a key; `on_split` allocates the child key and returns
   child hooks; `on_perturb` extends the key.
4. Engine: extend lower-and-delete and bisection to iterate streams;
   add whole-stream deletion as a pass between block deletion and
   redistribution.
5. Tests:
   - determinism: replaying the same multi-stream tape twice yields
     functions with identical observed behaviour;
   - shrinking: a property like "f applied to 0 returns true" minimises
     to a tape whose only surviving stream entry is that one bool, and
     a property over `List.filter f` shrinks both the list and `f`'s
     observed support;
   - realignment: shrinking an int that feeds `f` changes the salt and
     exercises the orphan-stream rule under all three policies;
   - regression files: an old single-stream tape still replays.

## Open questions

- Ordinal stability: split ordinals are per-parent counters. An edit
  that deletes an earlier split shifts later ordinals, orphaning their
  streams wholesale. Acceptable (same character as block deletion
  misalignment), but if it bites, keys could instead hash the position
  of the split marker in the main stream.
- Size: `fn` against a large argument domain can touch many salts. The
  per-stream sequences are as long as the result generator needs, so
  tape size is bounded by actual test usage, but shortlex then prefers
  fewer calls, which is a mild pressure towards tests that call `f`
  less. That seems right.
- OxCaml modes: hooks on split-off states extend the nonportable-data
  story to children. Same answer as before: hooked states do not cross
  capsules or domains; the parallel engine hands each worker its own
  root state and tape.

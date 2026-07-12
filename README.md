# tape: choice-tape shrinking for base_quickcheck

An OCaml port of the Hypothesis/Conjecture shrinking model: record
every random decision made during generation as a typed, bounded
choice; shrink by editing the recorded tape and replaying generation.
Existing base_quickcheck generators get integrated shrinking without
any changes, by interposing at the Splittable_random interface.

Status: early. The tape core (record, replay, shortlex order) works;
the Splittable_random shim and the shrink loop are next. See
design/choice-tape-for-base-quickcheck.md for the architecture and
milestones, and proptest-rs/proptest#658 for the sibling Rust port
this follows.

Build: `opam switch 5.3.0 && dune test`.

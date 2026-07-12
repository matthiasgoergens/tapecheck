# Code review findings (2026-07-12, 8 finders + 4 verifier batches)

Top 10 in the report to Matthias. Confirmed-but-cut (fix queue):
- sizes silently truncated vs upstream's raise; shrink_count semantics
  repurposed as total tape budget (tape_test.ml).
- Crossed bounds: draw_int/draw_float lack lo>hi guards on the
  replayed-choice path (Sr_real's guard lives in the sampler);
  deserialize accepts lo>hi records.
- Tape_test cannot pass ~domains; naive threading would spawn a pool
  per case (needs pool reuse across the sizes loop).
- copy aliases hook closures / captured tape (latent: only untaped
  states are copied today).
- README: vendor/splittable_random has LICENSE-JANESTREET.md not
  LICENSE.md as claimed; opam install line lists shadowed packages.
- Dead code: span subsystem, is_on, target_of.
- Hand-rolled int64 codec vs Bytes.set_int64_le/String.get_int64_le.
- clamp64 duplicates Tape.clamp_int64.
- run_case/eval_proposal/replay triplication + 0x7ea9e at three sites.
- first_failure pool/no-pool duplication; test_wrapper 4x module dup.

Refuted (do not fix):
- float_key infinity-minus-infinity NaN: unreachable, Sr_real.float
  raises on non-finite bounds before any choice is recorded.
- Benchmark DCE under Flambda2: build uses default flags, no -O3;
  measured no elimination. The 12% claim stands.
- Nondeterministic seed "deterministic": Base.Random self-inits from
  OS entropy when am_testing is false; finder's probe had used Stdlib
  Random in plain ocaml (wrong module).

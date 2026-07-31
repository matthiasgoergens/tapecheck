# Does tapecheck work on OxCaml?

It matters: Jane Street works in OxCaml, so a port that only builds on
stock OCaml is not usable by the people it is aimed at. `core` itself is
thick with mode annotations (`CORE-BUILD.md`), so this is not optional.

## Result: yes, and the numbers are identical

```
opam exec --switch=5.2.0+ox -- dune build --profile oxcaml          # clean
opam exec --switch=5.2.0+ox -- dune exec --profile oxcaml \
    test_regression/regression_guard.exe                            # all guards passed
```

Every benchmark reproduces exactly: 38 / 22 / 178 / 173 / 90 / 56,
zig-zag 83 of 83 at 30 calls, deep bind 158, self_len 47/100 at 170.
Not merely "it compiles" — the engine behaves identically.

The repo already carries an `oxcaml` dune profile, and a guard rule that
detects an ox switch and fails with *"OxCaml switch detected: build with
--profile oxcaml"* if you forget. That was set up earlier and works.

## But it violates two of their house rules

Building emits OxCaml-specific alerts, at `engine/tape_engine.ml:204`:

```
Alert do_not_spawn_domains: Stdlib.Domain.spawn
  User programs should never spawn domains. To execute a function on a
  domain, use [Multicore] from the threading library. This is because
  spawning more than [recommended_domain_count] domains (the CPU core
  count) will significantly degrade GC performance.

Alert unsafe_multidomain: Stdlib.Domain.spawn
  Use [Domain.Safe.spawn].
```

This is the parallel worker pool behind `?domains`. Two distinct
complaints:

1. **`do_not_spawn_domains`** — a policy alert. Our pool spawns
   `domains` workers on request, and nothing currently clamps that to
   `recommended_domain_count`. On their guidance that is a GC-performance
   footgun, and the alert exists because they have been bitten.
2. **`unsafe_multidomain`** — use `Domain.Safe.spawn`, which carries the
   mode discipline OxCaml uses to make cross-domain sharing sound.

They are alerts, not errors, so the build succeeds. But shipping
something to Jane Street that trips their own lints on every build is a
poor first impression, and the first alert is arguably a real bug: a
user passing `~domains:64` on an 8-core box gets exactly the degradation
the alert warns about.

## Suggested fixes, not yet done

- Clamp `domains` to `Domain.recommended_domain_count ()` and say so.
  That is a genuine fix independent of OxCaml.
- Switch to `Domain.Safe.spawn` where available, or route through
  `Multicore` on the ox profile.
- Consider making `?domains` default to 1 (it already does) and
  documenting that >1 is for long shrinks only — shrinking is off the CI
  happy path, which is the only place the pool pays.

## For the email

Worth one line: the port builds and behaves identically under OxCaml, so
it is usable where they actually work. Do not mention the alerts —
better to fix them first than to advertise them.

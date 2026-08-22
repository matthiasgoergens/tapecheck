# Real-world Tapecheck smoke test

This standalone consumer project tests the installed Tapecheck packages rather
than the vendored source workspace. It exercises:

- `Core_kernel.Fheap` against sorted-list semantics;
- mutable `Core_kernel.Pairing_heap` command sequences against a list model,
  including copying and clearing;
- textual and octet round trips through `Ipaddr.V4`; and
- Cstruct views, split/append, and endian reads and writes.

It also asks Tapecheck to falsify the plausible but false claim that draining a
priority heap preserves insertion order. This is a shrink-quality calibration,
not a defect in `Fheap`. At the outreach snapshot and default 2,000-attempt
budget, Tapecheck finds a two-element witness but leaves both integers very
large and reports truncation. Under the equivalent deterministic property,
Hypothesis 6.165.10 reports `[0, -1]`. The structural simplification works; the
coupled integer minimisation remains a real gap.

The comparison is pinned and deterministic:

```sh
uv run hypothesis_heap_order.py
```

Run this only after installing the three matching Tapecheck preview packages:

```sh
opam exec -- dune exec --root . ./test_real_world.exe
```

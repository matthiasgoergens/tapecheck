# Continuation-list probe results

`2026-08-11-hardening.txt` is the complete deterministic output from the
adversarial review's reproduction of `probe_list_design`.  It uses the
checked-in seeds and confirms the corrected attempts-per-found-failure table
in `WAVE2-CONTINUATION-LISTS.md`.

`2026-08-11-span-deletion.txt` is the complete deterministic output for the
subsequent checkpoint documented in `../../WAVE2-SPAN-DELETION.md`. Reproduce
it with:

```sh
nice -n 10 ionice -c 2 -n 7 opam exec --switch=5.3.0 -- \
  dune exec probe_list_design/probe_list_design.exe
```

`2026-08-12-leaf-budget.txt` extends the same deterministic probe with the
Hypothesis-shaped `max_leaves=100` prototype, recursive generation tails,
tape costs, retry counts, and a 50-seed recursive shrink-quality comparison.
It is documented in `../../WAVE2-LEAF-BUDGET.md` and reproduced by the same
command above.

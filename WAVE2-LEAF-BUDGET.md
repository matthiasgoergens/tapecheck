# Wave 2 checkpoint: an explicit recursive leaf budget

Measured 2026-08-12 on `wave2/span-deletion`, after the span-deletion
checkpoint. This is an experimental generator in `probe_list_design/`, not a
public Base Quickcheck API.

## Following Hypothesis's mechanism

Current Hypothesis exposes
[`recursive(base, extend, min_leaves=None, max_leaves=100)`](https://hypothesis.readthedocs.io/en/latest/reference/strategies.html#hypothesis.strategies.recursive).
Its implementation wraps `base` in a shared counter, builds a tower beginning
with `base` and `extend(base)`, then repeatedly adds
`extend(one_of(previous_levels))` while successive powers of two fit under the
leaf cap. If a draw asks for one base value beyond the cap, it abandons that
draw and retries from the advanced data stream.

The probe ports that mechanism directly:

- only successful draws from `base` consume leaves;
- recursive collection lengths do not share Base's ambient `~size` budget;
- the default cap is 100 leaves, matching Hypothesis;
- rejected over-cap attempts consume random/tape input before retrying;
- `min_leaves`, added to Hypothesis in 2026, is deliberately deferred.

This is materially different from merely decrementing `~size`. It adapts to
the branching structure produced by `extend`, while the cap remains a local
contract of the recursive generator rather than a universal composition rule.

The probe also copies Hypothesis's unbounded retry loop. The measured tree
generator terminates comfortably (at most nine retries here), but a production
API needs an explicit health-check policy for a pathological `extend` that can
never fit. There is one unavoidable OCaml-specific caveat too: Hypothesis's
private limit signal inherits from Python's `BaseException`, while an OCaml
generator using `try ... with _` can intercept the private exception and defeat
the cap. The eventual API must document or structurally prevent that case.

## Result

The cap makes the previously unsafe continuation-tree experiment finite. At
size 50 over 10,000 raw samples:

| Generator | Mean nodes | Maximum nodes | Maximum charged leaves |
|---|---:|---:|---:|
| Base recursive union + stock list | 9.50 | 50 | n/a |
| Hypothesis-shaped recursion + continuation/spans | 13.21 | 120 | 100 |

The extra twenty nodes are not a cap violation: empty internal nodes need not
draw a base leaf. Across two 10,000-sample measurements the capped generator
retried 15,820 times over 20,000 successful executions, with at most nine
retries for one execution.

On a simple recursive shrink test—fail at twenty total nodes—the combined
design was much stronger:

| Generator | Failures found | Exact 20-node minima | Worst minimum | Mean attempts/failure |
|---|---:|---:|---:|---:|
| Base recursive union + stock list | 50/50 | 14/50 | 50 | 2,079 |
| Leaf cap + continuation/spans | 50/50 | 50/50 | 20 | 168 |

This is not a proof that every recursive workload improves, but it is a strong
positive control: the new representation both respects its safety cap and
enables the structural deletion pass to reach every measured boundary.

## The remaining cost

Tape-attached, one-case generation over 1,000 deterministic seeds measured:

| Generator | Mean nodes | Mean choices | Maximum choices |
|---|---:|---:|---:|
| Base recursive union + stock list | 8.89 | 55.16 | 464 |
| Leaf cap + continuation/spans | 13.11 | 119.41 | 933 |

The capped arm deliberately explores somewhat larger trees, so this is not a
pure per-node performance comparison. It nevertheless shows the integration
cost clearly: failed over-cap attempts remain represented in Tapecheck's tape,
and the experiment made 720 retries over 1,000 fresh generator executions
during the taped measurement. The measurement records each seed directly;
engine determinism and live-value replays are deliberately outside the count.
Hypothesis has richer discarded-region tracking and shrinking machinery;
Tapecheck does not yet have an equivalent
`remove_discarded` pass.

Therefore the leaf cap closes the recursion-safety blocker, but it does not by
itself make the combined list generator ready to ship. The next experiment is
to delimit failed recursive attempts and remove their discarded tape regions,
then repeat the recursive quality and cost measurements. First-class string
and bytes choices remain independently necessary for the ten-strings case.

That follow-up is now complete; see `WAVE2-DISCARDED-REGIONS.md`.

## Reproduction

The complete deterministic output is
`probe_list_design/results/2026-08-12-leaf-budget.txt`. Reproduce it with:

```sh
nice -n 10 ionice -c 2 -n 7 opam exec --switch=5.3.0 -- \
  dune exec probe_list_design/probe_list_design.exe
```

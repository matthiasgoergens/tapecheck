# Wave 2 checkpoint: calculator generator migration

Measured 2026-08-12 on `wave2/span-deletion`, after the opt-in production
generator checkpoint.

## Question and design

Can `Generator.recursive_with_max_leaves` replace the calculator challenge's
size-threaded `recursive_union` without hurting discovery, while improving the
size and work of the resulting counterexamples?

The experimental unit is one deterministic seed, paired across the stock and
structural generator arms. The primary sample was fixed at 100 seeds before
inspection, using the challenge's size 8, 20,000-case search cap, and 20,000
shrink-proposal budget. Arm order alternates within consecutive seed blocks.
The recorded outcomes are discovery, exact normalisation, replay proposals,
node count, and rendered size. No wall-clock measurements are used, so machine
load and thermal drift are not part of the estimand.

The structural arm uses the Hypothesis-shaped default leaf cap of 100. Both
arms use the same literal, addition, and division alternatives and the same
property. A four-seed, 2,000-case harness calibration was run first and is
excluded from the analysis.

The executable is `diag2/probe_calculator.exe`. Individual observations are in
`diag2/calculator-structural-100.tsv`; the direct summary is in
`diag2/calculator-structural-100-summary.txt`. The reproducible paired analysis
is `diag2/analyse_calculator_structural.py`.

## Result

Both arms found a failure on all 100 seeds and each reached the challenge's
one exact canonical rendering once. The discordant exact outcomes were one in
each direction, so changing the generator does not by itself solve calculator
normalisation.

The generated/shrunk shapes were nevertheless substantially cleaner:

| measure among found failures | stock | structural | paired structural - stock |
|---|---:|---:|---:|
| mean replay proposals | 933.6 | 501.3 | -432.3 |
| mean nodes | 10.5 | 5.6 | -5.0 |
| mean rendered bytes | 62.3 | 37.7 | -24.6 |

Exploratory paired percentile-bootstrap 95% intervals (50,000 resamples, fixed
analysis seed) were `[-519.2, -349.2]` proposals, `[-5.9, -4.1]` nodes, and
`[-29.8, -19.6]` rendered bytes. These intervals were selected after the raw
results were available and are descriptive, not a preregistered confirmatory
analysis.

## Interpretation

Separating recursion from Base Quickcheck's ambient size is already useful: it
preserves discovery, roughly halves shrink work, and removes about five inert
nodes on average. It does not supply the missing `pass_to_descendant` operation.
The remaining noncanonical five-node answers are small failing subexpressions
with the wrong surrounding/operator arrangement; choosing a bounded recursive
distribution cannot promote the right descendant to the root.

This is therefore positive migration evidence for the opt-in generator API,
and negative evidence for treating generator design as a substitute for the
next structural shrink pass. The next implementation checkpoint should record
recursive-layer spans and implement replay-validated descendant promotion.

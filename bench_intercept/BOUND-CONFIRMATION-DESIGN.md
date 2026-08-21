# Optimised inactive seam: predeclared confirmation

The first bounded experiment found narrow, positive inactive-check costs and
failed its all-draw 5% rule because the float upper bound was 1.0951.  Native
inspection showed that the public functions routed the inactive case through
the generic backend-dispatch helper, loading the default closure before
entering the primitive body.

The implementation has now been changed so each public primitive matches its
observer field directly.  The inactive branch calls the same local default
body without passing it through the generic helper.  The helper remains in use
for the explicit backend-facing `Intercept.run_*` API.  Exploratory single
pairs were used while developing this edit and are not confirmation data.

This confirmation retains the original question, metrics, 1.05 maximum
practical slowdown, familywise-95% decision rule, three contrasts, 10,000,000
draws per arm, CPU, and no-exclusion rule.  It increases the predeclared sample
to 60 paired fresh-process invocations per draw kind and contrast.  The
bootstrap uses 100,000 resamples and seed `20260822`; generated PRNG seeds also
use a new `202608220` base.

The optimisation is confirmed only if all three isolated `seam/direct`
familywise upper bounds are at most 1.05 and the active-observer positive
control still passes its original all-draw rule.  The whole-module contrast
remains secondary because code layout is not isolated.  No result from the
first batch is pooled into the confirmation decision.

This design, the source optimisation, the regenerated pinned-upstream patch,
and the new sample size must be committed before the confirmation result
directory is created.

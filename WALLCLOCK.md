# Wall-clock: engine overhead per test call

Measured 2026-07-31, same six-property benchmark set, 100 seeds each.

```
tapecheck   8 rows, ~75,700 test calls,  0.67 s wall
hypothesis  6 rows, ~21,900 test calls, 13.34 s wall

  wall-clock ratio           19.9x
  tapecheck  per test call    8.9 us
  hypothesis per test call  609.1 us
  per-call ratio             68.8x
```

The wall ratio is not the honest figure: tapecheck runs eight rows to
Hypothesis's six (and a stock `base_quickcheck` arm alongside), and does
3.5x more test calls because its shrinker is more attempt-hungry. Per
test call is the fair comparison, and it makes the gap *larger*, not
smaller.

## What this is and is not measuring

The properties are trivial — sum a list, compare two ints — so almost
all of the per-call cost is **engine overhead**, not the test. That is
precisely what should be compared between engines, but it bounds the
claim: if a user's test does real work, the overhead matters less. A
test taking 1 ms sees 1.009 ms against 1.6 ms, which is 1.6x, not 69x.

So the honest statement is about *headroom*, not speed in general.

## Why headroom is the interesting part, and it lands on their RO1

RO1 reports practitioners budgeting 50 ms to 30 s for a whole property
test, and warns that coverage-measuring hybrids may not fit. Turn the
overhead figures into example counts within a 50 ms budget, assuming a
free test:

```
  tapecheck    ~5,600 examples
  hypothesis      ~82 examples
```

That is the same argument the paper makes about time constraints,
arriving from the other side: the constraint practitioners report is
partly a property of the engine they are using. Hypothesis's own
`target()` documentation notes the effect is "noticeable above ~1,000
examples and obvious around 10,000" — which is comfortably inside a
50 ms budget for one engine and nowhere near it for the other.

## Caveats worth carrying

- Machine was under other load; these are single runs, not distributions.
  The ratio is large enough that noise does not threaten it, but do not
  quote 68.8 as if it were precise. "Roughly two orders of magnitude"
  is the defensible claim.
- Python interpreter startup (~0.1 s) is included and is negligible
  against 13 s.
- This is OCaml versus Python, so a large part of the gap is the
  language, not the engine design. It is not evidence that the port is
  *better engineered* — only that it is cheaper to run, which is what
  determines how many examples a user can afford.

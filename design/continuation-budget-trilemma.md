# The continuation-budget trilemma

The continuation-list experiments leave one tempting instruction: reserve
enough budget for future list nodes, but keep each continuation choice adjacent
to the element it guards. Under Base's current hard size bound and length
support, that instruction has no non-degenerate online implementation.

## Claim

Consider a list generator at `size = B`, with minimum length zero and maximum
length `B`. Suppose it has all three properties:

1. **Payload-independent conditional length support.** After every online
   history for a continued prefix of length `i < B`, including the payload
   allocations already drawn, continuing to every final length through `B`
   still has positive probability. This is what it means here to retain
   Base's conditional log-uniform length decisions rather than correlate a
   hidden length commitment with payload spending.
2. **Current hard bound.** For every execution, final list length plus the sum
   of element size parameters is at most `B`.
3. **Online adjacency.** Once the continuation for element `i` says yes, that
   element is generated before the continuation for element `i + 1` is known.

Then every generated element must receive size zero.

## Proof

After the first continuation says yes, the final length `B` is still possible
by property 1. That execution spends all `B` units on list nodes. Property 2
therefore leaves zero payload budget for the first element. By property 3 its
size must be chosen now, before the generator can learn that the all-continue
suffix will not occur, so the first element must receive size zero on every
execution.

The same argument applies after each later continued prefix: final length `B`
still has positive probability, its node charges consume the complete bound,
and the current element is generated before that possibility is resolved.
Induction gives size zero for every element. Randomising the allocation does
not help: any positive-size outcome followed by the possible all-continue
suffix violates the hard bound.

The argument is about causality, not the particular conditional probabilities,
choice domains, or shrinker. With a smaller maximum `M < B`, the same proof
limits payload spent before the final length is known to `B - M`; it no longer
forces that payload to zero.

## What the two measured arms chose

The structurally charged online arm preserves properties 2 and 3. Once an
early element spends payload budget it forces a shorter suffix, violating
property 1; measured raw mean length fell from 3.591 to 1.956 at size 10.

The payload-only arm preserves properties 1 and 3. It does not charge nodes to
the payload bound, weakening property 2 to separate bounds on length and
payload. It restored reachability and recorded no leaf-cap retries, but failed
its size, hardest-case quality, and shrink-cost screens.

The unbudgeted continuation-span arm preserves properties 1 and 3 and gives
each element the ambient size. It abandons an aggregate payload bound, reaching
2,179 characters at size 50 in the measured string-list tail.

## Actual escape routes

A future design must visibly give up or reinterpret one premise:

- **Know the final length before generating elements.** This permits Base's
  exact allocation contract, but a mutable length choice before all elements
  recreates the tape realignment problem unless the shrinker receives a new
  atomic edit spanning that choice and the affected suffix.
- **Delay element generation until the continuation run is complete.** This
  also makes the budget known, but continuation choices are no longer adjacent
  to their elements. Recovering atomic deletion then needs an indirection or a
  structural mapping not represented by current contiguous spans.
- **Let spending constrain future continuation.** This is the measured
  structurally charged online arm; it changes the length distribution.
- **Separate structural and payload budgets.** This is a new public size
  contract. The measured payload-only version is not good enough, but a
  deliberately two-dimensional size API could still be investigated.
- **Relax the hard aggregate bound.** This must be explicit and accompanied by
  recursive tail controls; the unbudgeted arm shows why an implicit relaxation
  is unsafe.

The next productive work is therefore not another formula for an online scalar
budget. It is either an atomic length-and-suffix shrink operation, a
non-contiguous structural mapping, or an explicitly two-dimensional generator
contract.

# falsify: a third point in the design space

`well-typed/falsify` — "internal shrinking reimagined for Haskell". Read
because `SPANS-THE-ROOT-CAUSE.md` framed the question as a binary
choice, and it is not.

## The two positions I had

- **Hypothesis**: record at the STRATEGY layer. `start_span`/`stop_span`
  give labelled nested spans, so `pass_to_descendant`,
  `remove_discarded`, `reorder_spans` all have structure to work on.
  Cost: only strategies it owns are visible.
- **tapecheck**: record at the PRNG layer. Shrinks *unmodified*
  `base_quickcheck` generators, and sees a flat sequence of draws with no
  idea which belong together.

## falsify's position: the PRNG's SPLIT STRUCTURE *is* the tree

`Test.Falsify.SampleTree`:

```haskell
data SampleTree = SampleTree Sample SampleTree SampleTree | Minimal

fromPRNG g = let (n, _) = nextWord64 g
                 (l, r) = splitSMGen g
             in SampleTree (NotShrunk n) (go l) (go r)
```

An infinite binary tree where each node is *either* a drawn `Word64`
*or* a split into two subtrees — their comment calls it "the additive
conjunction from linear logic". Structure comes neither from the
strategy layer nor from nothing: it comes from **where the generator
split the PRNG**.

Two details worth stealing regardless:

- **`Minimal`** is a constructor, not a computed value. It represents an
  infinite all-zero tree finitely *and lets the shrinker RECOGNISE that
  a subtree is already minimal* — needed when generators produce
  infinite structures. tapecheck computes `image_trivialized` instead
  and cannot recognise minimality structurally.
- **`Sample = NotShrunk Word64 | Shrunk Word64`.** Each sample records
  whether it has already been shrunk. tapecheck has no such marking; it
  re-derives what to try from scratch each pass.

## CORRECTION, after reading the shrinker rather than the data structure

The section above is right about `SampleTree` and wrong about what
follows from it. Reading `Internal/Shrinking.hs` and
`Internal/Generator.hs`:

```haskell
newtype Gen a = Gen { runGen :: SampleTree -> (a, [SampleTree]) }
```

A falsify generator returns a value **and a list of already-shrunk
sample trees**. `bind` combines the candidates from both sides. The
engine's `shrinkFrom` then does almost nothing: take the candidates the
generator produced, keep the first that still fails, recurse.

So falsify does NOT derive shrinks from the split topology. **The
generator proposes them.** That is integrated shrinking in the Hedgehog
sense, moved from values onto sample trees. `SampleTree` is the
representation; the shrinking power comes from generator cooperation.

Which means my earlier inference was wrong. I wrote that our 47/100 ->
17/100 drop under split-per-element "looks like ours, not the
approach's, because falsify takes that route and shrinks well". falsify
does not demonstrate that an ENGINE-DRIVEN shrinker over split topology
works, because falsify's shrinker is not engine-driven. Nothing here
shows the drop is avoidable.

## The axis that actually matters

Not "where does structure come from" but **how much cooperation does the
shrinker need from the generator**:

| | cooperation required | who proposes shrinks |
|---|---|---|
| Hypothesis | strategies must call `start_span`/`stop_span` | engine, over spans |
| falsify | every combinator must emit candidate trees | **generator** |
| tapecheck | **none** — unmodified `base_quickcheck` | engine, over a flat tape |

Both alternatives buy their structure with generator cooperation.
tapecheck is the only one of the three that requires nothing, and the
missing span-dependent passes are the price of exactly that.

That is a better framing than "third position", and it makes the
question for the email sharper rather than softer: is zero-cooperation
viable for span-dependent passes at all, given that both other designs
pay for their structure — and if not, which currency is cheaper, spans
at the strategy layer or candidates from the generator?

Note also `instance Selective Gen`. Selective functors let you inspect
both branches of a choice without running either, which is plausibly how
falsify keeps structure visible under `bind`. Not yet followed up.

## Not yet read

`ShrinkTree.hs`, `Internal/`, `Driver.hs` — the actual shrinking
algorithm over the tree, which is the part that would say whether the
quality drop I measured is avoidable. Also their paper/blogpost
(`demo/demo/Demo/Blogpost.hs` references it), and their use of
`Control.Selective` — selective functors appear in the cabal deps of
every component, which suggests the generator applicative is doing
something deliberate about which branches are observable.


## A scar of theirs that does NOT transfer, and why that is interesting

`Internal/Search.hs` documents a parity bias:

> standard binary search is not very good at allowing search to flip
> between even and odd. For example, if we start with `maxBound`,
> *every* possible shrunk value computed by `binarySearch` is even.

They ship `binarySearchNoParityBias` to counter it, pairing each
candidate with its opposite-parity neighbour.

tapecheck's `minimize_integer` is also a halving search, so the bias
looked likely. Measured (`diag2/probe_parity.ml`, thresholds of each
parity, 40 seeds each): **240/240 exact on even thresholds, 240/240 on
odd**. No bias at all.

The reason is the thing worth keeping. falsify's `binarySearch` returns
a LIST OF CANDIDATE VALUES, computed up front — and that list is what
carries the bias. It has to be a list, because falsify's generators emit
their shrink candidates before any of them is tried
(`Gen a = SampleTree -> (a, [SampleTree])`). An engine-driven shrinker
has no such constraint: tapecheck's binary search is ADAPTIVE, narrowing
on the actual test outcome until it converges on the true boundary,
whatever its parity.

So generator-driven shrinking pays a price that is easy to miss:
candidates must be enumerated in advance, so the search cannot react to
what it learns. The parity bias is a symptom of that, not of binary
search.

This is the first case found where tapecheck's zero-cooperation position
is not merely cheaper but *better*. Worth stating in the email, because
the rest of the letter is honest about where the design costs us.

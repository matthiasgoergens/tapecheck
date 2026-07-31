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

## Why this matters for the open question

This is precisely the experiment I ran and misread. I tested making
`base_quickcheck` combinators split per element
(`diag2/probe_split.ml`): structure appeared exactly as predicted, one
stream per list element, tape halved — and shrink quality DROPPED, 47/100
to 17/100. I concluded it was "a real option with a real cost".

falsify says the cost is not intrinsic. It gets structure from exactly
that mechanism and shrinks well. What dropped was *our* quality, because
our passes work within a flat segment and the joint move they rely on
stops being expressible once elements live on separate streams. The
generator change needs a matching shrinker built for trees — which
falsify has and we do not.

So the honest form of the email's question changes. Not "is PRNG-level
recording a dead end for span-dependent passes?" but:

> Hypothesis takes structure from the strategy layer; falsify takes it
> from the PRNG's split topology. tapecheck currently takes it from
> neither. Given that `base_quickcheck` splits exactly once in its whole
> generator library, is the split-topology route open to us at all
> without changing those combinators — and if the combinators must
> change, is that a better bargain than owning the strategy layer?

That is a sharper question, and it has a real third option in it.

## Not yet read

`ShrinkTree.hs`, `Internal/`, `Driver.hs` — the actual shrinking
algorithm over the tree, which is the part that would say whether the
quality drop I measured is avoidable. Also their paper/blogpost
(`demo/demo/Demo/Blogpost.hs` references it), and their use of
`Control.Selective` — selective functors appear in the cabal deps of
every component, which suggests the generator applicative is doing
something deliberate about which branches are observable.

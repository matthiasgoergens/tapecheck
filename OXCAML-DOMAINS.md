# The second OxCaml alert: why a shim does not fix it

`unsafe_multidomain` says "Use `[Domain.Safe.spawn]`". Attempted, and it
is not a conditional-compilation problem — the shim approach is dead for
two independent reasons.

## 1. `Domain.Safe.spawn` carries the SAME first alert

From `~/.opam/5.2.0+ox/lib/ocaml/domain.mli:253`:

```ocaml
val spawn : (unit -> 'a) @ portable once -> 'a t
[@@alert do_not_spawn_domains
   "User programs should never spawn domains. To execute a function on a
    domain, use [Multicore] from the threading library. ..."]
```

So switching to it silences `unsafe_multidomain` and leaves
`do_not_spawn_domains` firing. Their actual guidance is not "use the
safe spawn" but "do not spawn domains at all; use `Multicore` from the
threading library".

## 2. It rejects our worker closure, by design

Tried it. The build says:

```
Error: The value "t" is "nonportable" but is expected to be "portable"
```

`Domain.Safe.spawn` requires a `portable` closure, which by its own
documentation "cannot close over and interact with any unsynchronized
mutable data in the current domain". Our `worker_loop t` closes over the
pool record: a `Stdlib.Mutex`, two condition variables, a mutable queue
and a mutable results array.

That data *is* synchronised — by the mutex — but the mode system cannot
see that, and it is right not to take our word for it. Making it
portable means expressing the synchronisation in a form the modes
understand, i.e. OxCaml's capsule/`Multicore` discipline rather than
`Stdlib.Mutex`.

## What this actually costs

A proper fix is an **OxCaml-only reimplementation of the worker pool**
against `Multicore`, not a one-line shim behind a dune profile. That is
real work, it is code that cannot be compiled or tested on stock OCaml,
and it buys parallel shrinking — which is off the CI happy path and
defaults to `~domains:1` anyway.

## Options, none taken yet

- **Restrict `?domains` to 1 on the oxcaml profile**, so the pool is
  simply not built there. Loses parallel shrinking on OxCaml, costs
  nothing else, and removes both alerts honestly rather than by
  suppression.
- **Reimplement the pool against `Multicore`** on the ox profile. The
  right answer if parallel shrinking matters to an OxCaml user.
- **Suppress the alerts with a comment.** Cheapest, and the worst: it
  advertises that we read their guidance and declined it, on a build
  they would run.

The first is probably right for now — `~domains:1` is already the
default, so almost nobody loses anything, and it is defensible rather
than suppressed. Not done pending a decision.

## What was fixed

The clamp to `recommended_domain_count` landed regardless, because that
one is a genuine footgun rather than a lint: nothing previously stopped
`~domains:1000` on a 32-core box. Results verified domain-invariant.

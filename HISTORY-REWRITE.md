# History rewrite, 2026-07-31

`master` was rewritten and force-pushed on 2026-07-31 to remove
`outreach/email-draft-2026-07-31.md`, which should never have been
committed here: this repository is public, and that file carried
notes-to-self about how to frame results for named recipients, a
recollection of a private conversation, and personal email addresses.
The email it drafts links to this very repository, so sending it would
have pointed its recipients at the reasoning behind it.

The draft now lives in a private repository. `outreach/` is gitignored
here so it cannot recur.

## What this means if you have an older clone

Every commit from the draft's introduction onward has a new SHA. Some
commit messages written before the rewrite cite the OLD SHAs — for
example, several fixes reference the commit they reviewed, and the
removal commit itself refers to `fd16523`. Those references no longer
resolve in this repository.

They were left as-is deliberately. Correcting them would mean rewriting
history a second time, which would invalidate a fresh set of SHAs and
achieve very little: the messages still describe what happened, and the
work they refer to is all present.

To resync an existing clone:

```
git fetch origin
git reset --hard origin/master
```

## What was NOT achieved

Force-pushing removes the objects from branch history but does not
compel GitHub to discard them. A commit SHA someone already holds may
remain fetchable until garbage collection. The exposure window was a few
hours on a repository with no watchers, and that residual risk was
accepted rather than escalated to GitHub Support.

## Nothing else was touched

Verified by diffing the rewritten tree against the original: the only
differences were the removed file and untracked build artefacts. The
full test suite passes on the rewritten history, and CI is green.

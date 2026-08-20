#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
product_dir=$(dirname -- "$script_dir")
evidence_dir=${TAPECHECK_EVIDENCE_DIR:-"$product_dir/../tapecheck-evidence"}

if test ! -d "$evidence_dir/.git"; then
  echo "evidence-snapshot: no Git checkout at $evidence_dir" >&2
  echo "set TAPECHECK_EVIDENCE_DIR to the companion checkout" >&2
  exit 1
fi

# The backticks are literal Markdown delimiters, not shell expressions.
# shellcheck disable=SC2016
pin=$(sed -n 's/^here to commit `\([0-9a-f]\{40\}\)`.*/\1/p' \
  "$product_dir/EVIDENCE.md")

if test -z "$pin"; then
  echo "evidence-snapshot: could not read the 40-character pin from EVIDENCE.md" >&2
  exit 1
fi

actual=$(git -C "$evidence_dir" rev-parse HEAD)
if test "$actual" != "$pin"; then
  echo "evidence-snapshot: checkout is at $actual, but EVIDENCE.md pins $pin" >&2
  exit 1
fi

if ! git -C "$evidence_dir" diff --quiet; then
  echo "evidence-snapshot: companion worktree has unstaged changes" >&2
  exit 1
fi

if ! git -C "$evidence_dir" diff --cached --quiet; then
  echo "evidence-snapshot: companion index has staged changes" >&2
  exit 1
fi

comparison="$evidence_dir/experiments/headline-shrink-table/CURRENT-COMPARISON.md"
if ! cmp "$product_dir/CURRENT-COMPARISON.md" "$comparison"; then
  echo "evidence-snapshot: generated comparison differs from the pinned evidence" >&2
  exit 1
fi

(
  cd "$evidence_dir"
  sha256sum --check --quiet legacy-imports.sha256
)

echo "evidence-snapshot: pin, generated comparison, and legacy imports match"

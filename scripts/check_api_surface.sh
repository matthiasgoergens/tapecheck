#!/bin/sh
# Guard against silently DROPPING a public function.
#
# Written after a merge resolver quietly discarded resume_result,
# resume_run and resume_run_exn -- 73 lines of one side against 1 line of
# the other, and the rule took the wrong side. The test suite happened to
# catch it because a test called one of them. Nothing structural would
# have.
#
# Compares the set of top-level `let` names in engine/ against a checked-in
# baseline. Additions are fine and update the baseline; REMOVALS fail, on
# the principle that deleting public API should be deliberate.
set -eu
cd "$(dirname "$0")/.."
BASE=scripts/api-surface.txt
CUR=$(mktemp)
trap 'rm -f "$CUR"' EXIT

grep --no-filename --extended-regexp '^let [a-z_]+' engine/*.ml \
  | sed --expression='s/^let \([a-z_0-9]*\).*/\1/' \
  | sort --unique > "$CUR"

if [ ! -f "$BASE" ]; then
  cp "$CUR" "$BASE"
  echo "api-surface: baseline created with $(wc -l < "$BASE") names"
  exit 0
fi

# Sort both sides explicitly: the baseline is edited by hand when a
# removal is deliberate, and comm silently misbehaves on unsorted input.
SB=$(mktemp); SC=$(mktemp)
trap 'rm -f "$CUR" "$SB" "$SC"' EXIT
sort --unique "$BASE" > "$SB"
sort --unique "$CUR" > "$SC"
REMOVED=$(comm -23 "$SB" "$SC")
ADDED=$(comm -13 "$SB" "$SC")

if [ -n "$ADDED" ]; then
  echo "api-surface: new names (baseline updated):"
  echo "$ADDED" | sed --expression='s/^/  + /'
fi

if [ -n "$REMOVED" ]; then
  echo "api-surface: FAIL -- these public names disappeared:"
  echo "$REMOVED" | sed --expression='s/^/  - /'
  echo ""
  echo "  If the removal is deliberate, update scripts/api-surface.txt."
  echo "  If it is not, something dropped them -- check merges first."
  exit 1
fi

cp "$CUR" "$BASE"
echo "api-surface: ok, $(wc -l < "$BASE") public names"

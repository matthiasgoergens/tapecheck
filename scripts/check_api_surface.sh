#!/bin/sh
# Guard against silently DROPPING a top-level engine function.
#
# Written after a merge resolver quietly discarded resume_result,
# resume_run and resume_run_exn -- 73 lines of one side against 1 line of
# the other, and the rule took the wrong side. The test suite happened to
# catch it because a test called one of them. Nothing structural would
# have.
#
# Compares the set of top-level `let` names in engine/ against the
# CHECKED-IN baseline, and never writes to it unless asked.
#
# It used to end with `cp "$CUR" "$BASE"`, which made the guard largely
# ornamental: CI runs in a disposable checkout, so adding a name passed
# without the committed baseline ever changing -- and a later deletion of
# that same name therefore also passed, because it had never been
# recorded. Only names predating the guard were actually protected.
#
# Additions now fail too. That is deliberate: the mechanism rests on the
# committed file being current, so drift has to be visible rather than
# absorbed. Run with --update to regenerate, then commit the result
# alongside the change that caused it.
set -eu
cd "$(dirname "$0")/.."
BASE=scripts/api-surface.txt
UPDATE=no
if [ "${1:-}" = "--update" ]; then UPDATE=yes; fi

CUR=$(mktemp)
SB=$(mktemp)
SC=$(mktemp)
trap 'rm -f "$CUR" "$SB" "$SC"' EXIT

grep --no-filename --extended-regexp '^let [a-z_]+' engine/*.ml \
  | sed --expression='s/^let \([a-z_0-9]*\).*/\1/' \
  | sort --unique > "$CUR"

if [ "$UPDATE" = yes ]; then
  cp "$CUR" "$BASE"
  echo "api-surface: baseline updated, $(wc -l < "$BASE") names -- commit it"
  exit 0
fi

if [ ! -f "$BASE" ]; then
  echo "api-surface: FAIL -- $BASE is missing."
  echo "  Run 'scripts/check_api_surface.sh --update' and commit the result."
  exit 1
fi

# Sort both sides explicitly: comm silently misbehaves on unsorted input.
sort --unique "$BASE" > "$SB"
sort --unique "$CUR" > "$SC"
REMOVED=$(comm -23 "$SB" "$SC")
ADDED=$(comm -13 "$SB" "$SC")

status=0

if [ -n "$REMOVED" ]; then
  echo "api-surface: FAIL -- these tracked engine names disappeared:"
  echo "$REMOVED" | sed --expression='s/^/  - /'
  echo ""
  echo "  If the removal is deliberate, run with --update and commit."
  echo "  If it is not, something dropped them -- check merges first."
  status=1
fi

if [ -n "$ADDED" ]; then
  echo "api-surface: FAIL -- these tracked engine names are not in the baseline:"
  echo "$ADDED" | sed --expression='s/^/  + /'
  echo ""
  echo "  Additions are fine, but the baseline has to record them or they"
  echo "  are not protected against a later silent removal."
  echo "  Run with --update and commit the result."
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "api-surface: ok, $(wc -l < "$BASE") tracked top-level engine names"
fi
exit "$status"

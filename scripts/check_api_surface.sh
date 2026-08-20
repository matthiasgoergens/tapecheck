#!/bin/sh
# Guard against silently DROPPING a public core declaration.
#
# Written after a merge resolver quietly discarded resume_result,
# resume_run and resume_run_exn -- 73 lines of one side against 1 line of
# the other, and the rule took the wrong side. The test suite happened to
# catch it because a test called one of them. Nothing structural would
# have.
#
# Compares module-qualified values, types, exceptions and modules from the tape,
# engine, and stateful libraries against the checked-in baseline. Once a
# compilation unit has an explicit interface, its
# public declarations count (including declarations one level inside a [sig]);
# units without an interface fall back to top-level implementation bindings.
# Qualifying names avoids one module silently masking a removal from another.
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

for source in tape/*.ml engine/*.ml stateful/*.ml; do
  module=$(basename "$source" .ml)
  interface=${source%.ml}.mli
  if [ -f "$interface" ]; then
    awk -v unit="$module" '
      function clean(name) {
        sub(/[:=].*$/, "", name)
        return name
      }
      function declaration(kind, name) {
        print unit "." prefix kind ":" clean(name)
      }
      {
        line = $0
        sub(/^[ \t]+/, "", line)
        count = split(line, field, /[ \t]+/)

        if (field[1] == "end" && $0 !~ /^[ \t]/) prefix = ""
        if (field[1] == "val") declaration("val", field[2])
        else if (field[1] == "exception") declaration("exception", field[2])
        else if (field[1] == "type") {
          for (i = 2; i <= count; i++) {
            if (field[i] ~ /^[a-z_][A-Za-z0-9_\047]*$/) {
              declaration("type", field[i])
              break
            }
          }
        }
        else if (field[1] == "module" && field[2] == "type") {
          declaration("module-type", field[3])
          if (line ~ /= sig[ \t]*$/) prefix = clean(field[3]) "."
        }
        else if (field[1] == "module") {
          declaration("module", field[2])
          if (line ~ /: sig[ \t]*$/) prefix = clean(field[2]) "."
        }
      }
    ' "$interface"
  else
    awk -v unit="$module" '
      function clean(name) {
        sub(/[:=].*$/, "", name)
        return name
      }
      function declaration(kind, name) {
        print unit "." kind ":" clean(name)
      }
      /^[^ \t]/ {
        count = split($0, field, /[ \t]+/)
        if (field[1] == "let") {
          name = field[2] == "rec" ? field[3] : field[2]
          if (name ~ /^[a-z_][A-Za-z0-9_\047]*$/) declaration("val", name)
        }
        else if (field[1] == "exception") declaration("exception", field[2])
        else if (field[1] == "type") {
          for (i = 2; i <= count; i++) {
            if (field[i] ~ /^[a-z_][A-Za-z0-9_\047]*$/) {
              declaration("type", field[i])
              break
            }
          }
        }
        else if (field[1] == "module" && field[2] == "type")
          declaration("module-type", field[3])
        else if (field[1] == "module") declaration("module", field[2])
      }
    ' "$source"
  fi
done | sort --unique > "$CUR"

if [ "$UPDATE" = yes ]; then
  cp "$CUR" "$BASE"
  echo "api-surface: baseline updated, $(wc -l < "$BASE") core declarations -- commit it"
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
  echo "api-surface: FAIL -- these tracked core declarations disappeared:"
  echo "$REMOVED" | sed --expression='s/^/  - /'
  echo ""
  echo "  If the removal is deliberate, run with --update and commit."
  echo "  If it is not, something dropped them -- check merges first."
  status=1
fi

if [ -n "$ADDED" ]; then
  echo "api-surface: FAIL -- these core declarations are not in the baseline:"
  echo "$ADDED" | sed --expression='s/^/  + /'
  echo ""
  echo "  Additions are fine, but the baseline has to record them or they"
  echo "  are not protected against a later silent removal."
  echo "  Run with --update and commit the result."
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "api-surface: ok, $(wc -l < "$BASE") tracked core declarations"
fi
exit "$status"

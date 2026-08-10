#!/bin/sh
# The Core-dependent dogfood is a separate Dune project with package-shaped
# copies of the tape seam and engine. Keep those copies honest: a green nested
# run only validates the current engine when the snapshots actually match it.
set -eu
cd "$(dirname "$0")/.."

status=0
while read -r source snapshot; do
  if ! cmp -s "$source" "$snapshot"; then
    echo "consumer-snapshot: stale $snapshot (source: $source)" >&2
    diff -u "$source" "$snapshot" >&2 || true
    status=1
  fi
done <<'EOF'
engine/tape_db.ml bonsai-tapecheck-hunt/engine/tape_db.ml
engine/tape_engine.ml bonsai-tapecheck-hunt/engine/tape_engine.ml
engine/tape_explain.ml bonsai-tapecheck-hunt/engine/tape_explain.ml
engine/tape_health.ml bonsai-tapecheck-hunt/engine/tape_health.ml
engine/tape_stats.ml bonsai-tapecheck-hunt/engine/tape_stats.ml
engine/tape_test.ml bonsai-tapecheck-hunt/engine/tape_test.ml
tape/tape.ml bonsai-tapecheck-hunt/pkgs/splittable_random/src/tape.ml
vendor/splittable_random/splittable_random.ml bonsai-tapecheck-hunt/pkgs/splittable_random/src/splittable_random.ml
vendor/sr_real/sr_real.ml bonsai-tapecheck-hunt/pkgs/splittable_random/src/sr_real.ml
vendor/sr_real/sr_real.mli bonsai-tapecheck-hunt/pkgs/splittable_random/src/sr_real.mli
vendor/base_quickcheck/generator.ml bonsai-tapecheck-hunt/pkgs/base_quickcheck/src/generator.ml
vendor/base_quickcheck/generator.mli bonsai-tapecheck-hunt/pkgs/base_quickcheck/src/generator.mli
EOF

if [ "$status" -eq 0 ]; then
  echo "consumer-snapshot: source copies match"
fi
exit "$status"

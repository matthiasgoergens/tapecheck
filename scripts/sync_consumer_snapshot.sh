#!/bin/sh
# Synchronise the package-shaped Core consumer with the canonical sources.
# This is deliberately offline: provenance of vendor/ is checked separately.
set -eu

case "${1:---check}" in
  --check) mode=check ;;
  --update) mode=update ;;
  *) echo "usage: $0 [--check|--update]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
status=0

sync_file () {
  source=$1
  snapshot=$2
  if [ "$mode" = update ]; then
    if ! cmp -s "$source" "$snapshot"; then
      cp "$source" "$snapshot"
      echo "consumer-snapshot: updated $snapshot"
    fi
  elif ! cmp -s "$source" "$snapshot"; then
    echo "consumer-snapshot: stale $snapshot (source: $source)" >&2
    diff -u "$source" "$snapshot" >&2 || true
    status=1
  fi
}

sync_dir () {
  source_dir=$1
  snapshot_dir=$2
  for source in "$source_dir"/*.ml "$source_dir"/*.mli; do
    [ -f "$source" ] || continue
    case "$source" in *.pp.ml|*.pp.mli) continue ;; esac
    sync_file "$source" "$snapshot_dir/${source##*/}"
  done
}

check_dir_inventory () {
  source_dir=$1
  snapshot_dir=$2
  for snapshot in "$snapshot_dir"/*.ml "$snapshot_dir"/*.mli; do
    [ -f "$snapshot" ] || continue
    case "$snapshot" in *.pp.ml|*.pp.mli) continue ;; esac
    source="$source_dir/${snapshot##*/}"
    if [ ! -f "$source" ]; then
      echo "consumer-snapshot: extra source file $snapshot" >&2
      echo "consumer-snapshot: remove it explicitly or add its canonical source" >&2
      status=1
    fi
  done
}

check_named_inventory () {
  snapshot_dir=$1
  shift
  for snapshot in "$snapshot_dir"/*.ml "$snapshot_dir"/*.mli; do
    [ -f "$snapshot" ] || continue
    case "$snapshot" in *.pp.ml|*.pp.mli) continue ;; esac
    found=0
    for allowed in "$@"; do
      if [ "${snapshot##*/}" = "$allowed" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      echo "consumer-snapshot: extra source file $snapshot" >&2
      echo "consumer-snapshot: remove it explicitly or add its canonical source" >&2
      status=1
    fi
  done
}

check_dir_inventory engine bonsai-tapecheck-hunt/engine
check_named_inventory bonsai-tapecheck-hunt/pkgs/splittable_random/src \
  tape.ml tape.mli splittable_random.ml sr_real.ml sr_real.mli
check_dir_inventory vendor/base_quickcheck bonsai-tapecheck-hunt/pkgs/base_quickcheck/src
check_dir_inventory vendor/ppx_quickcheck \
  bonsai-tapecheck-hunt/pkgs/base_quickcheck/ppx_quickcheck
check_dir_inventory vendor/ppx_quickcheck_expander \
  bonsai-tapecheck-hunt/pkgs/base_quickcheck/expander
check_dir_inventory vendor/ppx_quickcheck_runtime \
  bonsai-tapecheck-hunt/pkgs/base_quickcheck/runtime
if [ "$status" -ne 0 ]; then
  echo "consumer-snapshot: refusing a partial update; fix the inventory first" >&2
  exit "$status"
fi

sync_dir engine bonsai-tapecheck-hunt/engine
sync_file tape/tape.ml bonsai-tapecheck-hunt/pkgs/splittable_random/src/tape.ml
sync_file tape/tape.mli bonsai-tapecheck-hunt/pkgs/splittable_random/src/tape.mli
sync_file vendor/splittable_random/splittable_random.ml \
  bonsai-tapecheck-hunt/pkgs/splittable_random/src/splittable_random.ml
sync_file vendor/sr_real/sr_real.ml \
  bonsai-tapecheck-hunt/pkgs/splittable_random/src/sr_real.ml
sync_file vendor/sr_real/sr_real.mli \
  bonsai-tapecheck-hunt/pkgs/splittable_random/src/sr_real.mli
sync_dir vendor/base_quickcheck bonsai-tapecheck-hunt/pkgs/base_quickcheck/src
sync_dir vendor/ppx_quickcheck bonsai-tapecheck-hunt/pkgs/base_quickcheck/ppx_quickcheck
sync_dir vendor/ppx_quickcheck_expander bonsai-tapecheck-hunt/pkgs/base_quickcheck/expander
sync_dir vendor/ppx_quickcheck_runtime bonsai-tapecheck-hunt/pkgs/base_quickcheck/runtime

if [ "$status" -eq 0 ]; then
  if [ "$mode" = update ]; then
    echo "consumer-snapshot: update complete"
  else
    echo "consumer-snapshot: source copies match"
  fi
fi
exit "$status"

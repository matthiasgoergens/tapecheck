#!/bin/sh
# Verify that vendor/ is the pinned upstream release plus reviewed patches.
set -eu

case "${1:---check}" in
  --check) mode=check ;;
  --update) mode=update ;;
  *) echo "usage: $0 [--check|--update]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
root=$(pwd)
lock=vendor/upstream.lock
base_url=
base_tag=
base_commit=
sr_url=
sr_tag=
sr_commit=
seen_base=0
seen_sr=0

while read -r name url tag commit extra; do
  case "$name" in
    ''|'#'*) continue ;;
    base_quickcheck)
      if [ "$seen_base" -ne 0 ]; then
        echo "vendor-provenance: duplicate base_quickcheck entry in $lock" >&2
        exit 1
      fi
      seen_base=1
      base_url=$url; base_tag=$tag; base_commit=$commit ;;
    splittable_random)
      if [ "$seen_sr" -ne 0 ]; then
        echo "vendor-provenance: duplicate splittable_random entry in $lock" >&2
        exit 1
      fi
      seen_sr=1
      sr_url=$url; sr_tag=$tag; sr_commit=$commit ;;
    *) echo "vendor-provenance: unknown entry $name in $lock" >&2; exit 1 ;;
  esac
  if [ -n "${extra:-}" ]; then
    echo "vendor-provenance: malformed entry for $name in $lock" >&2
    exit 1
  fi
done < "$lock"

if [ -z "$base_url" ] || [ -z "$base_tag" ] || [ -z "$base_commit" ] \
   || [ -z "$sr_url" ] || [ -z "$sr_tag" ] || [ -z "$sr_commit" ]; then
  echo "vendor-provenance: $lock must pin both upstreams" >&2
  exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tapecheck-vendor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

fetch_release () {
  name=$1
  url=$2
  tag=$3
  expected=$4
  destination=$5
  case "$url" in -*) echo "vendor-provenance: invalid repository URL $url" >&2; exit 1 ;; esac
  if ! git check-ref-format "refs/tags/$tag" >/dev/null; then
    echo "vendor-provenance: invalid tag $tag" >&2
    exit 1
  fi
  case "$expected" in
    *[!0-9a-f]*|'')
      echo "vendor-provenance: invalid commit $expected" >&2
      exit 1 ;;
  esac
  if [ "${#expected}" -ne 40 ]; then
    echo "vendor-provenance: commit must be a full 40-character object ID" >&2
    exit 1
  fi
  git init --quiet "$destination"
  git -C "$destination" fetch --quiet --depth=1 "$url" "refs/tags/$tag"
  actual=$(git -C "$destination" rev-parse 'FETCH_HEAD^{commit}')
  if [ "$actual" != "$expected" ]; then
    echo "vendor-provenance: $name $tag resolves to $actual, expected $expected" >&2
    exit 1
  fi
  git -C "$destination" checkout --quiet --detach "$actual"
  echo "vendor-provenance: $name $tag -> $actual"
}

compare_file () {
  upstream=$1
  vendored=$2
  if [ "$mode" = update ]; then
    if ! cmp -s "$upstream" "$vendored"; then
      cp "$upstream" "$vendored"
      echo "vendor-provenance: updated $vendored"
    fi
  elif ! cmp -s "$upstream" "$vendored"; then
    echo "vendor-provenance: $vendored differs from patched upstream $upstream" >&2
    diff -u "$upstream" "$vendored" >&2 || true
    status=1
  fi
}

compare_dir () {
  upstream_dir=$1
  vendor_dir=$2
  for upstream in "$upstream_dir"/*.ml "$upstream_dir"/*.mli; do
    [ -f "$upstream" ] || continue
    compare_file "$upstream" "$vendor_dir/${upstream##*/}"
  done
}

check_dir_inventory () {
  # These Jane Street source components are deliberately flat. Top-level
  # additions are detected in [compare_dir]; a future nested layout should be
  # modelled explicitly rather than flattened silently.
  upstream_dir=$1
  vendor_dir=$2
  for vendored in "$vendor_dir"/*.ml "$vendor_dir"/*.mli; do
    [ -f "$vendored" ] || continue
    upstream="$upstream_dir/${vendored##*/}"
    if [ ! -f "$upstream" ]; then
      echo "vendor-provenance: $vendored has no file in patched upstream" >&2
      status=1
    fi
  done
}

base="$tmp/base_quickcheck"
sr="$tmp/splittable_random"
fetch_release base_quickcheck "$base_url" "$base_tag" "$base_commit" "$base"
fetch_release splittable_random "$sr_url" "$sr_tag" "$sr_commit" "$sr"
base_patch="vendor/patches/base_quickcheck-$base_tag.patch"
sr_patch="vendor/patches/splittable_random-$sr_tag.patch"
if [ ! -f "$base_patch" ] || [ ! -f "$sr_patch" ]; then
  echo "vendor-provenance: each pinned tag needs a same-named patch file" >&2
  exit 1
fi
for declared_patch in vendor/patches/*.patch; do
  case "$declared_patch" in
    "$base_patch"|"$sr_patch") ;;
    *) echo "vendor-provenance: orphan patch $declared_patch" >&2; exit 1 ;;
  esac
done
git -C "$base" apply "$root/$base_patch"
git -C "$sr" apply "$root/$sr_patch"

status=0
check_dir_inventory "$base/src" vendor/base_quickcheck
check_dir_inventory "$base/ppx_quickcheck/src" vendor/ppx_quickcheck
check_dir_inventory "$base/ppx_quickcheck/expander" vendor/ppx_quickcheck_expander
check_dir_inventory "$base/ppx_quickcheck/runtime" vendor/ppx_quickcheck_runtime
if [ "$status" -ne 0 ]; then
  if [ "$mode" = update ]; then
    echo "vendor-provenance: refusing a partial refresh; fix the inventory first" >&2
  else
    echo "vendor-provenance: vendored source inventory does not match upstream" >&2
  fi
  exit "$status"
fi
if [ "$mode" = update ]; then
  # Do not change canonical files unless the current consumer snapshot has a
  # complete, self-consistent inventory that the final update can replace.
  ./scripts/sync_consumer_snapshot.sh --check
fi
compare_dir "$base/src" vendor/base_quickcheck
compare_dir "$base/ppx_quickcheck/src" vendor/ppx_quickcheck
compare_dir "$base/ppx_quickcheck/expander" vendor/ppx_quickcheck_expander
compare_dir "$base/ppx_quickcheck/runtime" vendor/ppx_quickcheck_runtime
compare_file "$base/LICENSE.md" vendor/base_quickcheck/LICENSE.md
compare_file "$base/LICENSE.md" vendor/ppx_quickcheck/LICENSE.md
compare_file "$base/LICENSE.md" vendor/ppx_quickcheck_expander/LICENSE.md
compare_file "$base/LICENSE.md" vendor/ppx_quickcheck_runtime/LICENSE.md
compare_file "$sr/src/splittable_random.ml" vendor/sr_real/sr_real.ml
compare_file "$sr/src/splittable_random.mli" vendor/sr_real/sr_real.mli
compare_file "$sr/LICENSE.md" vendor/sr_real/LICENSE.md
compare_file "$sr/LICENSE.md" vendor/splittable_random/LICENSE.md

if [ "$status" -ne 0 ]; then
  exit "$status"
fi
if [ "$mode" = update ]; then
  ./scripts/sync_consumer_snapshot.sh --update
  echo "vendor-provenance: refresh complete"
else
  echo "vendor-provenance: vendored sources equal pinned releases plus declared patches"
fi

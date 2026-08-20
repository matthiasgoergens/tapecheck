#!/bin/sh
# Backwards-compatible check-only entry point. The synchroniser also has an
# explicit --update mode for refreshing the package-shaped consumer.
set -eu
if [ "$#" -ne 0 ]; then
  echo "usage: $0" >&2
  echo "use sync_consumer_snapshot.sh --update to refresh" >&2
  exit 2
fi
exec "$(dirname "$0")/sync_consumer_snapshot.sh" --check

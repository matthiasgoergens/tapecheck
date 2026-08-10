#!/bin/sh
# Rebuild canonical vendored sources and then their consumer snapshot from the
# pinned upstream releases plus the reviewed patches under vendor/patches/.
set -eu
exec "$(dirname "$0")/check_vendor_provenance.sh" --update

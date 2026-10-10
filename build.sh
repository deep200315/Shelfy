#!/bin/sh
# Local convenience wrapper; see scripts/package_app.sh.
exec "$(dirname "$0")/scripts/package_app.sh" "$@"

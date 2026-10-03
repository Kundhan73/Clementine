#!/bin/bash
# Runs a CI step, mirroring its output into $RUNNER_TEMP/ci-logs/<name>.log so
# that report-failure.sh can post the tail of the failing step.
# Usage: scripts/ci/step.sh <name> <command> [args...]
set -uo pipefail
name="$1"; shift
dir="${RUNNER_TEMP:-/tmp}/ci-logs"
mkdir -p "$dir"
echo "$name" > "$dir/.current"
"$@" 2>&1 | tee "$dir/$name.log"
status=${PIPESTATUS[0]}
[ "$status" = 0 ] && rm -f "$dir/.current"
exit "$status"

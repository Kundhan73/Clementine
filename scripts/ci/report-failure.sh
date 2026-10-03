#!/bin/bash
# Posts the last 150 lines of the failing step as a commit comment (a fallback
# channel for reading CI errors without downloading logs).
# Usage: scripts/ci/report-failure.sh <job-name>
set -uo pipefail
job="${1:-build}"
dir="${RUNNER_TEMP:-/tmp}/ci-logs"
step="$(cat "$dir/.current" 2>/dev/null || true)"
body="$(mktemp)"
{
  echo "### CI failure: \`$job\`${step:+ / step \`$step\`}"
  echo
  echo "Run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  echo
  if [ -n "$step" ] && [ -f "$dir/$step.log" ]; then
    echo '```'
    # Strip ANSI colour codes and keep the comment well under GitHub's limit.
    tail -n 150 "$dir/$step.log" | sed -e 's/\x1b\[[0-9;]*m//g' | cut -c1-400
    echo '```'
  else
    echo "(no step log captured; see the run)"
  fi
} > "$body"
gh api "repos/$GITHUB_REPOSITORY/commits/$GITHUB_SHA/comments" -F "body=@$body" >/dev/null \
  && echo "posted failure comment" || echo "could not post failure comment"

#!/usr/bin/env bash
# ci/release-report.sh — file a failed release-check job as a GitHub issue (label release-check).
#   Usage: bash ci/release-report.sh <job> <tag> <sha> <run-url>     (needs gh, GH_TOKEN and GH_REPO)
# One open issue per job: while it is open, a later failure of the same job adds a comment instead of a new issue.
# Called by .github/workflows/release-check.yml; see docs/engineering/release-routine.md.
set -euo pipefail

job=${1:?usage: ci/release-report.sh <job> <tag> <sha> <run-url>}
tag=${2:?usage: ci/release-report.sh <job> <tag> <sha> <run-url>}
sha=${3:?usage: ci/release-report.sh <job> <tag> <sha> <run-url>}
run=${4:?usage: ci/release-report.sh <job> <tag> <sha> <run-url>}
label=release-check
prefix="release-check: $job failed"

body="The \`$job\` job of the release check failed on \`$tag\` (\`$sha\`).

Run log: $run

Reproduce it with a failing test in its own task (\`bash scripts/new-task.sh <name>\`), fix it through a normal PR,
and close this issue when the fix is released."

# Best effort: the label may already exist, or the token may not be allowed to create labels.
gh label create "$label" --color B60205 --description "Failure found by the release check" --force >/dev/null 2>&1 || true

# gh's own --jq (no jq binary needed): open issues of this job only, by exact title prefix.
open=$(gh issue list --label "$label" --state open --search "\"$prefix\" in:title" --json number,title \
  --jq "[.[] | select(.title | startswith(\"$prefix\"))][0].number // empty")

if [ -n "$open" ]; then
  gh issue comment "$open" --body "$body"
  echo "release-report: commented on issue #$open"
else
  gh issue create --label "$label" --title "$prefix on $tag" --body "$body"
fi

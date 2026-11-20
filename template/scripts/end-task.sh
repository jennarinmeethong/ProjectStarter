#!/usr/bin/env bash
# Remove a finished task's worktree and branch: bash scripts/end-task.sh <name> [--force]
# Refuses uncommitted changes always, and commits not in the default branch unless --force (work would be lost).
set -euo pipefail

name="${1:-}"
force="${2:-}"

die() { echo "end-task: $*" >&2; exit 1; }

[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "usage: bash scripts/end-task.sh <name> [--force]"
[ -z "$force" ] || [ "$force" = --force ] || die "unknown option '$force'"

main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
path="$(dirname "$main")/$(basename "$main")-tasks/$name"
branch="task/$name"

[ -f "$path/.task/env" ] || die "no task '$name' at $path"
# Compare git's own spelling of both paths (Git Bash can name one directory as /c/..., /tmp/... or C:/...).
here=$(git rev-parse --show-toplevel | tr '[:upper:]' '[:lower:]')
[ "$here" != "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" ] || die "run this from outside the task's worktree"

[ -z "$(git -C "$path" status --porcelain)" ] || die "$path has uncommitted changes; commit or discard them first"

default=$(git symbolic-ref -q --short refs/remotes/origin/HEAD || echo main)
if [ "$force" != --force ] && ! git merge-base --is-ancestor "$branch" "$default"; then
  die "$branch has commits that are not in $default. Merge its PR first, or pass --force to drop them"
fi

# Stop the task's containers, if any (best effort: Docker may not be installed or running).
project=$(sed -n 's/^export COMPOSE_PROJECT_NAME=//p' "$path/.task/env")
if command -v docker >/dev/null 2>&1 && [ -f "$path/compose.yaml" ]; then
  (cd "$path" && docker compose -p "$project" down --remove-orphans >/dev/null 2>&1) || true
fi

# status above was clean, so --force only drops ignored files (.task/, dependencies, build output).
git worktree remove --force "$path"
git branch -q -D "$branch"
echo "Task '$name' removed ($path, $branch)."

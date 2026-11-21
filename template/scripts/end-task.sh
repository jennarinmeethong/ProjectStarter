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

# Merged into what: origin's default branch (fetched first, so a PR merged on GitHub counts), else the main checkout's branch.
merged() {
  local default mb squashed
  if git remote | grep -qx origin; then
    GIT_TERMINAL_PROMPT=0 git fetch -q origin 2>/dev/null || echo "end-task: could not fetch origin; using what is already fetched" >&2
  fi
  default=$(git symbolic-ref -q --short refs/remotes/origin/HEAD \
    || git worktree list --porcelain | sed -n '1,/^$/s/^branch refs\/heads\///p')
  git rev-parse --verify -q "${default:-HEAD}^{commit}" >/dev/null && [ -n "$default" ] \
    || die "cannot find the default branch; run 'git remote set-head origin -a', or pass --force"
  git merge-base --is-ancestor "$branch" "$default" && return 0
  # Squash or rebase merge: the branch's commits are not in the default branch, but the same change is.
  mb=$(git merge-base "$default" "$branch") || return 1
  # A throwaway commit, never referenced; a fixed identity keeps it working where git has none set (CI, fresh machines).
  squashed=$(GIT_AUTHOR_NAME=end-task GIT_AUTHOR_EMAIL=end-task@localhost \
    GIT_COMMITTER_NAME=end-task GIT_COMMITTER_EMAIL=end-task@localhost \
    git commit-tree "$branch^{tree}" -p "$mb" -m squash) || return 1
  [[ "$(git cherry "$default" "$squashed")" == -* ]] && return 0
  echo "end-task: $branch has changes that are not in $default" >&2
  return 1
}
if [ "$force" != --force ] && ! merged; then
  die "merge its PR first (and fetch), or pass --force to drop the work"
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

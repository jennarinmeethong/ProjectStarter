#!/usr/bin/env bash
# Install the project-starter skill for Claude Code and/or Codex (user scope).
# Usage: scripts/install-skill.sh [claude] [codex]     (default: both)
#   Claude Code -> ~/.claude/skills/project-starter
#   Codex       -> ~/.agents/skills/project-starter
# The skill records where this repository lives so it can find copier.yml from any folder.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
src="$repo/skills/project-starter"
[ -f "$repo/copier.yml" ] || { echo "copier.yml not found in $repo" >&2; exit 1; }

targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(claude codex)

for t in "${targets[@]}"; do
  case "$t" in
    claude) dest="$HOME/.claude/skills/project-starter" ;;
    codex)  dest="$HOME/.agents/skills/project-starter" ;;
    *) echo "Unknown target: $t (use claude or codex)" >&2; exit 1 ;;
  esac
  mkdir -p "$dest"
  cp "$src/SKILL.md" "$dest/SKILL.md"
  template_path="$repo"
  if command -v cygpath >/dev/null 2>&1; then template_path=$(cygpath -m "$repo"); fi
  printf '%s\n' "$template_path" > "$dest/template-path.txt"
  echo "Installed project-starter skill for $t -> $dest (template: $template_path)"
done

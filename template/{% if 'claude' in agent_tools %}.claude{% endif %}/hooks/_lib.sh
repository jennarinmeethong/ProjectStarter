#!/usr/bin/env bash
# Shared helpers for Claude Code hooks. Works with or without jq (Git Bash on Windows has no jq by default).

# read_file_path: prints tool_input.file_path from the hook JSON on stdin, with '/' separators.
read_file_path() {
  local json path
  json=$(cat)
  if command -v jq >/dev/null 2>&1; then
    path=$(printf '%s' "$json" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  else
    path=$(printf '%s' "$json" | sed -n 's/.*"\(file_path\|notebook_path\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p' | head -n 1)
  fi
  printf '%s' "$path" | tr '\\' '/' | sed 's#//*#/#g'
}

# project_root: the project directory with '/' separators.
project_root() {
  printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}" | tr '\\' '/' | sed 's#//*#/#g; s#/$##'
}

# relative_path <abs-or-rel-path>: path relative to the project root (case-insensitive prefix match for Windows).
relative_path() {
  local p="$1" root lower_p lower_root
  root=$(project_root)
  lower_p=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')
  lower_root=$(printf '%s' "$root" | tr '[:upper:]' '[:lower:]')
  case "$lower_p" in
    "$lower_root"/*) printf '%s' "${p:${#root}+1}" ;;
    *) printf '%s' "${p#./}" ;;
  esac
}

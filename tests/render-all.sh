#!/usr/bin/env bash
# Render every stack x agent-tool combination, then for each stack:
#   1. the generated project passes its own verify command, and
#   2. the guardrails reject a seeded violation (escape hatch, layer leak, skipped test).
# Usage: tests/render-all.sh [stack...]      (default: typescript python dotnet)
# Needs: uv, git, bash; node/npm for typescript; .NET 10 SDK for dotnet.
set -uo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/project-starter-XXXXXX")
stacks=("$@")
[ ${#stacks[@]} -gt 0 ] || stacks=(typescript python dotnet)
failures=0

pass() { echo "  PASS $*"; }
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }

render() { # render <stack> <tools-json> <dest> [extra copier args...]
  uvx copier copy --trust --defaults --quiet \
    -d project_name=demo-app -d stack="$1" -d "agent_tools=$2" "${@:4}" "$repo" "$3" >/dev/null 2>&1
}

verify() { # verify <label> <command-string>: must succeed; show the tail of the output when it does not
  local out
  if out=$(bash -c "$2" 2>&1); then pass "$1"; else fail "$1"; printf '%s\n' "$out" | tail -n 15 | sed 's/^/      /'; fi
}

expect_fail() { # expect_fail <label> <command...>
  if "${@:2}" >/dev/null 2>&1; then fail "$1 (should have failed)"; else pass "$1 rejected"; fi
}

for stack in "${stacks[@]}"; do
  echo "== $stack"

  # Agent-tool combinations: only the file set changes.
  # The both-tools render also sets a guardrail owner; the others leave it empty (no CODEOWNERS).
  for tools in '["claude"]' '["codex"]' '["claude","codex"]'; do
    d="$work/$stack-$(echo "$tools" | tr -dc 'a-z,')"
    if [ "$tools" = '["claude","codex"]' ]; then owner_args=(-d guardrail_owner=@demo-org/platform); else owner_args=(); fi
    render "$stack" "$tools" "$d" "${owner_args[@]}" || { fail "render $tools"; continue; }
    if [ ${#owner_args[@]} -gt 0 ]; then
      grep -q '@demo-org/platform' "$d/.github/CODEOWNERS" 2>/dev/null && pass "CODEOWNERS with owner ($tools)" || fail "CODEOWNERS missing ($tools)"
    else
      if [ ! -e "$d/.github/CODEOWNERS" ] && ! grep -rIq '@your-org\|owned by  ' "$d"; then
        pass "no CODEOWNERS without owner ($tools)"
      else
        fail "CODEOWNERS or placeholder owner generated without an owner ($tools)"
      fi
    fi
    lines=$(wc -l < "$d/AGENTS.md")
    [ "$lines" -lt 60 ] && pass "AGENTS.md $lines lines ($tools)" || fail "AGENTS.md too long: $lines ($tools)"
    if [[ "$tools" == *claude* ]]; then
      [ -f "$d/CLAUDE.md" ] && [ -f "$d/.claude/settings.json" ] && pass "claude files ($tools)" || fail "claude files missing ($tools)"
    else
      [ ! -e "$d/CLAUDE.md" ] && [ ! -e "$d/.claude" ] && pass "no claude files ($tools)" || fail "unexpected claude files ($tools)"
    fi
    if grep -rIl '{{\|{%' "$d" --exclude-dir=node_modules --exclude-dir=.venv --exclude=ci.yml >/dev/null; then
      fail "unrendered Jinja in $(grep -rIl '{{\|{%' "$d" --exclude=ci.yml | head -1)"
    fi
  done

  # Full verification on the both-tools render.
  d="$work/$stack-claude,codex"
  cd "$d" || continue
  git init -q -b main && git add -A && git -c user.name=t -c user.email=t@t commit -qm base && git branch -q base
  case "$stack" in
    typescript)
      npm install --no-audit --no-fund >/dev/null 2>&1
      verify "npm run verify" "npm run verify"
      printf '\nimport { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";\nexport const leak = new InMemoryArtifactStore() as any;\n' >> src/domain/export-job.ts
      expect_fail "eslint: as any" npm run lint
      expect_fail "depcruise: domain -> adapters" npm run arch
      ;;
    python)
      uv sync >/dev/null 2>&1
      verify "python verify" "uv run pyright && uv run ruff check . && uv run ruff format --check . && uv run lint-imports && uv run pytest -q"
      printf '\nfrom demo_app.adapters.in_memory_artifact_store import InMemoryArtifactStore  # noqa\nleak: int = InMemoryArtifactStore()  # type: ignore\n' >> src/demo_app/domain/export_job.py
      expect_fail "pyright: type: ignore disabled" uv run pyright
      expect_fail "ruff: blanket noqa/type: ignore" uv run ruff check .
      expect_fail "import-linter: domain -> adapters" uv run lint-imports
      ;;
    dotnet)
      verify "dotnet verify" "dotnet build && dotnet format --verify-no-changes --no-restore && dotnet test --no-build"
      printf '\npublic static class Leak\n{\n#pragma warning disable CA1823\n    public static string Value = null!;\n}\n' >> src/DemoApp.Domain/ExportJob.cs
      expect_fail "build: TreatWarningsAsErrors" dotnet build
      ;;
  esac
  # Ratchet: commit the violation plus a skipped test and compare with base.
  case "$stack" in
    typescript) sed -i 's/  it("rejects/  it.skip("rejects/' src/domain/export-job.test.ts ;;
    python) sed -i 's/^def test_rejects/@pytest.mark.skip\ndef test_rejects/' tests/test_export_job.py ;;
    dotnet) sed -i 's/\[Fact\]/[Fact(Skip = "x")]/' tests/DemoApp.Tests/ExportJobTests.cs ;;
  esac
  git -c user.name=t -c user.email=t@t commit -qam violation
  expect_fail "guardrail-ratchet" bash ci/guardrail-ratchet.sh base

  # Claude Code hook: guardrail configs are protected.
  if [ -f .claude/hooks/protect-guardrails.sh ]; then
    first=$(sed -n 's/.*"Edit(\/\([^*)]*\))".*/\1/p' .claude/settings.json | head -1)
    echo "{\"tool_input\":{\"file_path\":\"$first\"}}" | CLAUDE_PROJECT_DIR="$d" bash .claude/hooks/protect-guardrails.sh 2>/dev/null
    [ $? -eq 2 ] && pass "hook blocks edit of $first" || fail "hook did not block $first"
  fi
  cd "$repo" || exit 1
done

echo
echo "Rendered into $work"
if [ "$failures" -eq 0 ]; then echo "ALL PASSED"; else echo "$failures FAILURE(S)"; exit 1; fi

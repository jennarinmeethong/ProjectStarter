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

seeded() { # seeded <label> <file> <text-to-append> <command...>: append, expect the command to fail, restore
  local file=$2
  printf '%b' "$3" >> "$file"
  expect_fail "$1" "${@:4}"
  git checkout -q -- "$file"
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
      # Dependency audit: clean on the render, rejects a known-vulnerable package.
      verify "npm audit" "npm audit --audit-level=high"
      cp package.json package-lock.json "$work/"
      npm install --no-audit --no-fund lodash@4.17.20 >/dev/null 2>&1
      expect_fail "npm audit: vulnerable dependency" npm audit --audit-level=high
      cp "$work/package.json" "$work/package-lock.json" . && npm install --no-audit --no-fund >/dev/null 2>&1
      # Design rules (ADR 0002), one violation at a time.
      seeded "eslint: ambient clock in domain" src/domain/export-job.ts '\nexport const now = (): number => Date.now();\n' npm run lint
      seeded "eslint: too many parameters" src/application/complete-export.ts '\nexport function sum(a: number, b: number, c: number, d: number, e: number): number {\n  return a + b + c + d + e;\n}\n' npm run lint
      seeded "eslint: non-exhaustive switch" src/domain/export-job.ts '\nexport function label(job: ExportJob): string {\n  switch (job.kind) {\n    case "queued":\n      return "q";\n    default:\n      return "other";\n  }\n}\n' npm run lint
      seeded "sonarjs: cognitive complexity" src/application/complete-export.ts '\nexport function grade(a: number, b: number, c: boolean): string {\n  let out = "";\n  for (let i = 0; i < a; i++) {\n    if (i > b && c) {\n      out += i % 2 === 0 ? "e" : "o";\n    } else if (i < b || !c) {\n      for (let j = 0; j < b; j++) {\n        if (j === i) {\n          out += j > 1 ? "x" : "y";\n        } else if (j > i && c) {\n          out += "z";\n        }\n      }\n    }\n  }\n  return out;\n}\n' npm run lint
      seeded "sonarjs: duplicated branches" src/domain/export-job.ts '\nexport function pick(job: ReadyExport, flag: boolean): string {\n  if (flag) {\n    return job.id.trim();\n  } else {\n    return job.id.trim();\n  }\n}\n' npm run lint
      seeded "depcruise: npm package in domain" src/domain/export-job.ts '\nimport fc from "fast-check";\nexport const gen = fc;\n' npm run arch
      seeded "depcruise: node built-in in application" src/application/complete-export.ts '\nimport { readFileSync } from "node:fs";\nexport const read = readFileSync;\n' npm run arch
      printf '\nimport { InMemoryArtifactStore } from "../adapters/in-memory-artifact-store.ts";\nexport const leak = new InMemoryArtifactStore() as any;\n' >> src/domain/export-job.ts
      expect_fail "eslint: as any" npm run lint
      expect_fail "depcruise: domain -> adapters" npm run arch
      ;;
    python)
      uv sync >/dev/null 2>&1
      verify "python verify" "uv run pyright && uv run ruff check . && uv run ruff format --check . && uv run lint-imports && uv run pytest -q"
      # Dependency audit: clean on the render, rejects a known-vulnerable package.
      verify "uv audit" "uv audit --locked --preview-features audit-command"
      cp pyproject.toml uv.lock "$work/"
      uv add --no-sync requests==2.19.0 >/dev/null 2>&1
      expect_fail "uv audit: vulnerable dependency" uv audit --locked --preview-features audit-command
      cp "$work/pyproject.toml" "$work/uv.lock" .
      # Design rules (ADR 0002), one violation at a time.
      seeded "ruff: ambient randomness in domain" src/demo_app/domain/export_job.py '\n\nimport random\n\n\ndef roll() -> float:\n    return random.random()\n' uv run ruff check .
      seeded "ruff: ambient clock in application" src/demo_app/application/complete_export.py '\n\ndef now() -> object:\n    import datetime\n\n    return datetime.datetime.now(tz=datetime.UTC)\n' uv run ruff check .
      seeded "ruff: too many arguments" src/demo_app/application/complete_export.py '\n\ndef total(a: int, b: int, c: int, d: int, e: int) -> int:\n    return a + b + c + d + e\n' uv run ruff check .
      seeded "ruff: boolean flag parameter" src/demo_app/domain/export_job.py '\n\ndef describe(job: ReadyExport, verbose: bool) -> str:\n    return job.artifact_key if verbose else job.id\n' uv run ruff check .
      seeded "pyright: implicit override" src/demo_app/adapters/in_memory_artifact_store.py '\n\nclass Loud(InMemoryArtifactStore):\n    def read(self, key: str) -> str | None:\n        return key\n' uv run pyright
      printf '\nfrom demo_app.adapters.in_memory_artifact_store import InMemoryArtifactStore  # noqa\nleak: int = InMemoryArtifactStore()  # type: ignore\n' >> src/demo_app/domain/export_job.py
      expect_fail "pyright: type: ignore disabled" uv run pyright
      expect_fail "ruff: blanket noqa/type: ignore" uv run ruff check .
      expect_fail "import-linter: domain -> adapters" uv run lint-imports
      ;;
    dotnet)
      verify "dotnet verify" "dotnet build && dotnet format --verify-no-changes --no-restore && dotnet test --no-build"
      # Dependency audit (NuGetAudit + TreatWarningsAsErrors): clean, then rejects a known-vulnerable package.
      verify "nuget audit" "dotnet restore --force-evaluate"
      sed -i 's#<PackageVersion Include="xunit.v3"#<PackageVersion Include="Newtonsoft.Json" Version="12.0.1" />\n    &#' Directory.Packages.props
      sed -i 's#</Project>#  <ItemGroup><PackageReference Include="Newtonsoft.Json" /></ItemGroup>\n</Project>#' src/DemoApp.Adapters/DemoApp.Adapters.csproj
      expect_fail "nuget audit: vulnerable dependency" dotnet restore --force-evaluate
      git checkout -q -- Directory.Packages.props src/DemoApp.Adapters/DemoApp.Adapters.csproj && dotnet restore --force-evaluate >/dev/null 2>&1
      # Design rules (ADR 0002), one violation at a time.
      seeded "BannedApi: ambient clock in Domain" src/DemoApp.Domain/ExportJob.cs '\npublic static class Clock\n{\n    public static DateTime Now() => DateTime.UtcNow;\n}\n' dotnet build
      seeded "BannedApi: Guid.NewGuid in Application" src/DemoApp.Application/CompleteExport.cs '\npublic static class Ids\n{\n    public static Guid Next() => Guid.NewGuid();\n}\n' dotnet build
      seeded "naming: async method without Async suffix" src/DemoApp.Adapters/InMemoryArtifactStore.cs '\npublic static class Waits\n{\n    public static async Task Pause() => await Task.CompletedTask.ConfigureAwait(false);\n}\n' dotnet build
      seeded "NetArchTest: unsealed concrete class" src/DemoApp.Application/CompleteExport.cs '\npublic class Helper\n{\n    public int Value { get; init; }\n}\n' dotnet test --filter-trait "Category=Architecture"
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

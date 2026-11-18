# Mutation testing in generated projects (phase 5c)

## Why

`docs/roadmap.md` phase 4 asks for "mutation testing เป็นระยะ" and "mutation score ไม่ลดลง", but no stack shipped a tool or
command. Mutation testing is the check that the tests actually pin behaviour down (coverage only says code ran). The
first measurement proved the point: the domain tests of three stacks let mutants survive (below).

## Goals / non-goals

- Goal: every stack gets one command, `cmd.mutation`, that mutates the **domain layer** and fails below the threshold.
- Goal: generated CI runs it on every PR/push (domain is small: seconds to a few minutes) as its own `mutation` job.
- Goal: the template's own domain tests reach 100% so a fresh project starts green.
- Goal: `tests/render-all.sh` proves the gate works: clean domain passes; an untested branch fails.
- Non-goal: mutating application/adapters (slow, needs containers). Teams widen the scope in the config file.
- Non-goal: running mutation on Windows natively for every tool (mutmut needs fork; gremlins and Stryker.NET misbehave on
  Windows). CI (Linux) is the gate; docs say Linux/macOS/WSL for local runs where that applies.

## Approaches

| | What | Trade-off |
|---|---|---|
| **A (picked)** | Domain-only mutation on every PR, break threshold 99% | Fast, catches weak tests at review time; strict for a tiny domain |
| B | Weekly scheduled run, report only | Cheap, but "score must not drop" is never enforced |
| C | Whole codebase on schedule | Real picture, but slow and needs datastore containers |

Picked A: the domain is where tier-2 logic lives (risk-tiers.md) and it runs in seconds, so it can gate PRs.

## Design (per stack)

| Stack | Tool (license) | Command | Threshold lives in |
|---|---|---|---|
| TypeScript | Stryker 10 + vitest runner (Apache-2.0) | `npm run mutation` → `stryker run` | `stryker.config.json` (`break: 99`) |
| Python | mutmut 3 (BSD-3) | `uv run mutmut run && uv run mutmut export-cicd-stats && uv run python ci/mutation-gate.py` | `ci/mutation-gate.py` (`THRESHOLD = 99`) — mutmut has no break option |
| .NET | Stryker.NET 5.1 (Apache-2.0), local tool, `test-runner: mtp` | `cd tests/<Name>.Domain.Tests && dotnet tool restore && dotnet stryker` | `tests/<Name>.Domain.Tests/stryker-config.json` (`break: 99`); domain tests live in their own project so the run needs no Docker (MTP has no test filter) |
| Go | gremlins v0.5.1 (Apache-2.0) via `go run …@v0.5.1` (no go.mod change) | `go run github.com/go-gremlins/gremlins/cmd/gremlins@v0.5.1 unleash ./internal/domain` | `.gremlins.yaml` (`efficacy: 99`; gremlins fails at exactly 100 even when all are killed) |
| Rust | cargo-mutants (MIT) | `cargo mutants -p domain` | none: any missed mutant fails (= 100%) |

- Threshold 99 rather than 100 where configurable: equal to "no survivors" until a domain has >100 mutants, and avoids
  gremlins' off-by-one. Each threshold file joins `stk.guardrail_files` (protected like the lint configs).
- Template tests strengthened where mutants survived: TS (start state, error message), Python (exact message),
  .NET (null guards, ParamName, message), Rust (accessors, `ExportJob::id`, `Display`). Go: measured at 100%.
- Generated CI: job `mutation` with the stack's setup steps then `cmd.mutation`.
- AGENTS.md: one line with the command. ADR/roadmap: phase 4 mutation item marked installed.
- Ignore files: `.stryker-tmp/`, `reports/` (TS), `mutants/` (Python), `StrykerOutput/` (.NET), `mutants.out*/` (Rust).
- render-all.sh: run `cmd.mutation` on the full render (datastores + HTTP API) and on the default render; on the default one also seed `if len(key) > 1024 → error` (an untested
  boundary) and expect the mutation command to fail.

## Left to the builder

- Exact CI setup steps (reuse the verify job's per-stack setup).
- Whether Windows local runs work for TS/Rust (they should; documented, not gated).

# CI for the ProjectStarter repo (phase 5a)

## Why

`bash tests/render-all.sh` is the only gate for template changes. Run locally it is very slow (every stack, many Docker
datastores, five frontends) and needs Docker, Node, .NET 10, Go 1.26, rustup and cargo-deny on one machine. The repo has
no CI of its own, so a PR can merge without the full run. Goal: GitHub runs it for every PR, in parallel, so nobody has to
run the whole thing locally.

## Goals / non-goals

- Goal: every PR into `main` and every push to `main` runs `tests/render-all.sh` for all five stacks, and its result shows on the PR.
- Goal: wall time is the slowest single stack, not the sum.
- Non-goal: changing `tests/render-all.sh` (splitting check groups is option B, only if TypeScript turns out too slow).
- Non-goal: a Windows runner (Windows Docker cannot run the Linux service containers). Git Bash compatibility stays a local check.
- Non-goal: running `claude plugin validate .` in CI (needs the Claude Code CLI on the runner).
- Anti-goal: a CI that differs from what `render-all.sh` checks locally — the workflow only installs tools and calls the script.

## Approaches

| | What | Trade-off |
|---|---|---|
| **A (picked)** | Matrix of 5 jobs, one per stack, each `bash tests/render-all.sh <stack>` | No script change; wall time = TypeScript job |
| B | Add a check-group flag to the script, matrix stack × group (~10–12 jobs) | Faster, but refactors a 695-line script |
| C | Fast render+verify on every PR, full run nightly or on a label | Quickest PR feedback; some breakage found only after merge |

Picked A: least change, and it gives real per-stack timings to decide whether B is needed later.

## Design

- New file `.github/workflows/render-all.yml` at the repo root (separate from `template/.github/`, which is rendered output).
- Triggers: `pull_request` to `main`, `push` to `main`, `workflow_dispatch`. No `paths-ignore`: a skipped workflow never
  reports, so once the checks are required a docs-only PR would wait forever (changed after review).
- A "Free disk space" step first in every matrix job (removes Android SDK, GHC, CodeQL from the runner): each job pulls
  every datastore image, and Rust builds one `target/` per render (added after review).
- `concurrency` per ref with `cancel-in-progress: true`.
- `strategy.matrix.stack: [typescript, python, dotnet, go, rust]`, `fail-fast: false`, `runs-on: ubuntu-latest`, `timeout-minutes: 120`.
- Steps: checkout → `astral-sh/setup-uv` (all) → `actions/setup-node` 24 (all; TypeScript needs it, other stacks' checks may call node/npx)
  → per stack: `actions/setup-dotnet` 10.0.x, `actions/setup-go` 1.26.x, Rust via preinstalled rustup + `taiki-e/install-action` for cargo-deny
  → TypeScript only: `npx playwright install-deps chromium` (system libraries for the browser tests)
  → `bash tests/render-all.sh ${{ matrix.stack }}`.
- Action versions match the ones the generated CI already uses (`checkout@v4`, `setup-node@v4`, `setup-uv@v6`, `setup-dotnet@v4`, `setup-go@v5`, `install-action@v2`).
- One small extra job, `whitespace`: `git diff --check` of the PR against its base (the CLAUDE.md check).
- Docs: `CLAUDE.md` and `README.md` say CI runs the full suite; running it locally is still possible for one stack.

## Left to the builder

- Whether other stacks also need Playwright browsers or system deps (find out from the first CI run and add the step where needed).
- Caching (npm, NuGet, Go, cargo) — only if the first timings show it matters.

## After merge (user's call, not part of this change)

- Mark the five `render-all` checks as required in branch protection for `main`.

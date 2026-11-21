# Parallel tasks in worktrees (roadmap phase 6)

## Why

Generated `docs/roadmap.md` phase 6 asks for "worktree / sandbox ต่องาน, agent ขนานหลายตัว". The source
(`docs/combined.md` §336, H5) says: one task → one worktree → one branch → one PR; isolate ports, test data and caches
per task; record base SHA, file scope, acceptance tests and PR dependencies; limit work in progress; and trust first,
then parallel. The template ships none of this, and two worktrees of a generated project collide today: the Playwright
configs pin ports (`8787` API e2e for TypeScript and Rust, `8788` ssr `e2e-ui`, `4173` TypeScript frontend) and
`compose.yaml` publishes fixed host ports (`8080`, `8081`).

## Goals / non-goals / anti-goals

- Goal: a human starts N isolated tasks with one command each; agents in each can run every test command at the same
  time without port or compose collisions.
- Goal: the task record (base SHA, scope, acceptance tests, depends-on PRs) exists from the start and goes into the PR.
- Goal: a work-in-progress limit enforced by the script, not by prose.
- Goal: works in Git Bash on Windows without `jq`; Claude Code and Codex both covered.
- Non-goal: CI checks on open-PR count or PR dependencies; a merge queue; orchestrating agents (spawning them is the
  human's or the tool's job).
- Anti-goal: changing default behaviour in the main checkout. Without the per-task env every port stays as it is now.

## Approaches

1. **Local kit (chosen):** env-overridable ports + `scripts/new-task.sh` / `scripts/end-task.sh` + a doc. Fixes the
   real collision and enforces the WIP limit where it is cheapest.
2. Docs only: cheapest, but leaves the port collision and puts a rule in prose (against `where-rules-live.md`).
3. Kit + CI checks (open-PR limit, depends-on): premature; the roadmap gates parallel work on trust metrics first.

The user picked 1.

## Design

### Ports and compose read the environment

| File | Variable | Default (unchanged) |
|---|---|---|
| `playwright.config.ts` (TS), `e2e/playwright.config.ts` (Rust) | `E2E_PORT` | 8787 |
| `e2e-ui/playwright.config.ts` (ssr) | `UI_PORT` | 8788 |
| `playwright.ui.config.ts` (TS frontend) | `UI_PORT` | 4173 |
| `compose.yaml` app / web host ports | `APP_PORT` / `WEB_PORT` | 8080 / 8081 |

Python and .NET API/UI tests already bind port 0; Go uses `httptest`; Testcontainers maps random ports. Server `PORT`
already reads the environment.

### `scripts/new-task.sh <name> [base-ref]`

- Validates `<name>` (`[a-z0-9-]+`) and that the repo has at least one commit; refuses if the branch or path exists.
  Uncommitted changes in the main checkout do not block (the new branch starts from a commit).
- WIP limit: counts existing task worktrees; refuses when `>= ${MAX_TASKS:-3}` with a message pointing at
  `docs/engineering/parallel-work.md`. `MAX_TASKS` overrides.
- Creates branch `task/<name>` from `base-ref` (default: current `HEAD`) in worktree `../<repo>-tasks/<name>` (a
  sibling, so linters, `dotnet` globbing and test discovery in the main checkout never see it).
- Picks the lowest free slot `n` (1..99) not used by another task's `.task/env`; ports are
  `20000 + n*100 + {0: PORT, 1: APP_PORT, 2: E2E_PORT, 3: UI_PORT, 4: WEB_PORT}`.
- Writes into the worktree (all gitignored):
  - `.task/env`: `export` lines for the ports and `COMPOSE_PROJECT_NAME=<project>-<name>`.
  - `.task/brief.md`: name, branch, base SHA, date, ports, and empty sections *Scope (files/dirs)*, *Acceptance
    tests*, *Depends on PRs*, *Owner*: the PR description starts from it.
  - Claude render only: `.claude/settings.local.json` with an `env` block holding the same variables, so every command
    the agent runs gets them without sourcing.
- Prints the next steps: `cd <path>`, `source .task/env` (shell / Codex CLI), start the agent.

### `scripts/end-task.sh <name>`

Refuses if the worktree has uncommitted changes, or (unless `--force`) its branch is not merged into the default
branch; otherwise `git worktree remove` and deletes the local branch. Runs `docker compose down` for the task's compose
project when Docker is present.

### Docs and pointers

- `docs/engineering/parallel-work.md`: when to start (phase 0–4 signals; "trust first, then parallel"), the
  one-task-one-PR rule, the commands above, splitting work so tasks do not touch the same files, coordinating shared
  interfaces, Claude Code (start `claude` inside the task worktree; `claude --worktree` is fine for throwaway work but
  does not get the port block), Codex (cloud tasks are already sandboxed per task; local Codex CLI: `source .task/env`).
- `AGENTS.md`: one line under "Where things are" (stays under 60 lines).
- `roadmap.md.jinja`: tick the phase 6 worktree item, pointing at the doc and the scripts.
- `.gitignore` of every stack: `.task/` and `.claude/settings.local.json`.
- `scripts/` is not a guardrail path (my call: it changes no check, and humans run it).

### Tests (`tests/render-all.sh`, core shard, every stack)

In one rendered project (git init + commit): `new-task.sh a` and `new-task.sh b` succeed with distinct ports in
`.task/env`; a fourth task fails with `MAX_TASKS=3`; `.task/` is ignored by `git status`; Claude renders get
`settings.local.json` with `E2E_PORT`; `end-task.sh` refuses a dirty worktree and removes a clean merged one. For the
TypeScript render with `http_api`, run `test:e2e` once with `E2E_PORT` set to a non-default port.

## Left to the builder

Exact messages, the ignore check style, whether `end-task.sh` lists tasks when called without a name.

# Parallel Worktrees Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generated projects can run several agent tasks at once, each in its own worktree with its own ports, under a
work-in-progress limit.

**Architecture:** Test ports and compose host ports read env vars with today's values as defaults. Two bash scripts in
the generated `scripts/` create and remove task worktrees and write a per-task env file (plus Claude's
`settings.local.json`). A doc explains the workflow; `tests/render-all.sh` exercises the scripts in the full render.

**Tech Stack:** Copier/Jinja templates, bash (Git Bash compatible, no `jq`), Playwright configs (TS), Docker Compose.

**Spec:** `docs/superpowers/specs/2026-11-20-parallel-worktrees-design.md`

## Global Constraints

- Defaults unchanged: `E2E_PORT` 8787, `UI_PORT` 8788 (ssr) / 4173 (TS frontend), `APP_PORT` 8080, `WEB_PORT` 8081.
- Task ports: `20000 + slot*100 + {0: PORT, 1: APP_PORT, 2: E2E_PORT, 3: UI_PORT, 4: WEB_PORT}`, slot = lowest free 1..99.
- Worktree path `../<repo-dir>-tasks/<name>`, branch `task/<name>`, name matches `^[a-z0-9][a-z0-9-]*$`.
- WIP limit `${MAX_TASKS:-3}` task worktrees (a worktree is a task when it has `.task/env`).
- `COMPOSE_PROJECT_NAME=<project_name|lower>-<name>`.
- Scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, no `jq`, work in Git Bash on Windows.
- Generated `AGENTS.md` stays under 60 lines.

## Review Focus

- Running `new-task.sh` from inside a task worktree: the task must still land under the main checkout's sibling
  `-tasks` dir (resolve the main worktree via `git worktree list --porcelain`, first entry). Test in Task 2.
- A slot freed by `end-task.sh` is reused by the next `new-task.sh`. Test in Task 3.
- Windows paths from `git worktree list` (`C:/...`) must work with `[ -f ]`; no `cygpath` needed in Git Bash. Covered by
  running render-all on Windows locally.
- `end-task.sh` on a branch with commits not in the default branch refuses without `--force`. Test in Task 3.
- `.task/` and `.claude/settings.local.json` never show in `git status`. Test in Task 2.

---

### Task 1: Ports and compose read the environment

**Files:**
- Modify: `template/{% if stack == 'typescript' and http_api %}playwright.config.ts{% endif %}` (line 5)
- Modify: `template/{% if stack == 'rust' and http_api %}e2e{% endif %}/playwright.config.ts` (line 5)
- Modify: `template/{% if frontend != 'none' %}e2e-ui{% endif %}/{% if frontend == 'ssr' %}playwright.config.ts{% endif %}.jinja` (line 4)
- Modify: `template/{% if stack == 'typescript' and frontend != 'none' %}playwright.ui.config.ts{% endif %}.jinja` (line 4)
- Modify: `template/{% if containerize %}compose.yaml{% endif %}.jinja` (lines 16, 314)
- Test: `tests/render-all.sh` (full TypeScript render, before `http_checks typescript`)

**Interfaces:** Produces env vars `E2E_PORT`, `UI_PORT`, `APP_PORT`, `WEB_PORT` consumed by Task 2's env file.

- [ ] **Step 1: Add the test** — in the typescript branch of the full render, before `http_checks typescript`:
  `verify "playwright: API tests on E2E_PORT=28702" "E2E_PORT=28702 npm run test:e2e"`, and after rendering assert
  `grep -q 'process.env.E2E_PORT' playwright.config.ts && grep -q 'APP_PORT:-8080' compose.yaml` → pass
  `"ports read the environment"`.
- [ ] **Step 2: Run** `SHARD=core bash tests/render-all.sh typescript` — expect FAIL on "ports read the environment".
- [ ] **Step 3: Implement** — `const port = Number(process.env.E2E_PORT ?? "8787");` (and `UI_PORT` with 8788 / 4173);
  compose: `"127.0.0.1:${APP_PORT:-8080}:8080"` and `"127.0.0.1:${WEB_PORT:-8081}:8080"`. Escape `${` for Jinja only if
  needed (it is not: Jinja ignores `${`).
- [ ] **Step 4: Run** the same command — expect PASS for both new lines and nothing newly failing.
- [ ] **Step 5: Commit** `template: test ports and compose host ports read the environment`

### Task 2: `scripts/new-task.sh`

**Files:**
- Create: `template/scripts/new-task.sh.jinja`
- Modify: the five stack `.gitignore` templates (add `.task/` and `.claude/settings.local.json`)
- Test: `tests/render-all.sh` — new `task_checks()` called after `automerge_checks` in the full render

**Interfaces:**
- Produces: `bash scripts/new-task.sh <name> [base-ref]`, exit 0 and prints the worktree path on its last line;
  exit 1 with a message on bad name / existing branch or path / WIP limit.
- Produces in the worktree: `.task/env` with lines `export TASK_SLOT=<n>`, `export PORT=…`, `export APP_PORT=…`,
  `export E2E_PORT=…`, `export UI_PORT=…`, `export WEB_PORT=…`, `export COMPOSE_PROJECT_NAME=…`;
  `.task/brief.md` (name, branch, base SHA, date, ports, empty *Scope*, *Acceptance tests*, *Depends on PRs*, *Owner*);
  Claude renders only: `.claude/settings.local.json` `{"env": {…same keys as strings…}}`.

- [ ] **Step 1: Write `task_checks`** (runs in `$d`, a git repo on `main`):
  - `bash scripts/new-task.sh a` and `… b` succeed; `../$(basename "$d")-tasks/a/.task/env` has `TASK_SLOT=1` and
    `E2E_PORT=20102`; `b` has `TASK_SLOT=2` and `E2E_PORT=20202` → pass `"new-task: two tasks, distinct ports"`.
  - `(cd ../…-tasks/a && bash scripts/new-task.sh c)` creates `../…-tasks/c` (not nested) → pass `"new-task: from a task worktree"`.
  - `expect_fail "new-task: fourth task over MAX_TASKS=3" bash scripts/new-task.sh d`.
  - `expect_fail "new-task: bad name" bash scripts/new-task.sh Bad_Name`.
  - `git -C ../…-tasks/a status --porcelain` is empty → pass `"new-task: task files ignored"`.
  - `grep -q '"E2E_PORT": "20102"' ../…-tasks/a/.claude/settings.local.json` → pass `"new-task: claude env"`.
  - `grep -q "$(git rev-parse main)" ../…-tasks/a/.task/brief.md` → pass `"new-task: brief has base SHA"`.
- [ ] **Step 2: Run** `SHARD=core bash tests/render-all.sh python` — expect FAIL (script missing).
- [ ] **Step 3: Implement `template/scripts/new-task.sh.jinja`.** Main checkout = first `worktree ` line of
  `git worktree list --porcelain`; tasks dir = `$(dirname main)/$(basename main)-tasks`. Count/slots from
  `<each worktree>/.task/env` (`TASK_SLOT=` line). `git worktree add -b "task/$name" "$path" "${2:-HEAD}"`. The
  `settings.local.json` block sits inside `{% if 'claude' in agent_tools %}`. Last line printed: the path; before it,
  next steps (`cd`, `source .task/env`, start the agent, read `docs/engineering/parallel-work.md`).
- [ ] **Step 4: Run** the same command — expect all `new-task:` lines PASS.
- [ ] **Step 5: Commit** `template: scripts/new-task.sh creates a task worktree with its own ports`

### Task 3: `scripts/end-task.sh`

**Files:**
- Create: `template/scripts/end-task.sh`
- Test: extend `task_checks()`

**Interfaces:**
- Consumes: task layout from Task 2.
- Produces: `bash scripts/end-task.sh <name> [--force]`; default branch = `origin/HEAD` target if set, else `main`.
  Refuses (exit 1) on uncommitted changes, or on commits not in the default branch unless `--force`. Otherwise
  `docker compose -p "$COMPOSE_PROJECT_NAME" down` if `docker` exists (ignore its failure), `git worktree remove`,
  `git branch -D task/<name>`.

- [ ] **Step 1: Extend `task_checks`:**
  - touch `../…-tasks/a/x.txt`; `expect_fail "end-task: dirty worktree" bash scripts/end-task.sh a`; remove the file.
  - commit a file on `task/b`; `expect_fail "end-task: unmerged branch" bash scripts/end-task.sh b`; then
    `bash scripts/end-task.sh b --force` succeeds and the dir and branch are gone → pass `"end-task: --force"`.
  - `bash scripts/end-task.sh a` succeeds; then `bash scripts/new-task.sh e` gets `TASK_SLOT=1` → pass
    `"end-task: slot reused"`. Clean up `c` and `e` with `end-task.sh` at the end.
- [ ] **Step 2: Run** `SHARD=core bash tests/render-all.sh python` — expect FAIL.
- [ ] **Step 3: Implement** `template/scripts/end-task.sh` (plain file, no Jinja).
- [ ] **Step 4: Run** — expect all `end-task:` lines PASS.
- [ ] **Step 5: Commit** `template: scripts/end-task.sh removes a finished task`

### Task 4: Docs, AGENTS.md, roadmap

**Files:**
- Create: `template/docs/engineering/parallel-work.md.jinja`
- Modify: `template/AGENTS.md.jinja` (one bullet under "Where things are")
- Modify: `template/docs/roadmap.md.jinja` (phase 6 first item → `[x]` with pointer)
- Modify: `README.md` (one row or line mentioning `scripts/new-task.sh`)
- Test: `task_checks()` asserts `grep -q 'scripts/new-task.sh' AGENTS.md docs/engineering/parallel-work.md`

- [ ] **Step 1: Add the assertion**, run `SHARD=core bash tests/render-all.sh python` — expect FAIL.
- [ ] **Step 2: Write the doc** (Thai, matching `where-rules-live.md` tone): when to start (phase 0–4 signals; trust
  first, then parallel), one task → one worktree → one branch → one PR, split tasks by files and coordinate shared
  interfaces, the two scripts and `MAX_TASKS`, the brief → PR description, Claude Code (`claude` inside the worktree;
  `--worktree` gets no port block), Codex (cloud tasks are sandboxed; local CLI: `source .task/env`), cleanup.
  Codex/Claude sections conditional on `agent_tools`.
- [ ] **Step 3: AGENTS bullet:** `- Parallel tasks: one worktree each via \`bash scripts/new-task.sh <name>\` (\`docs/engineering/parallel-work.md\`).`
- [ ] **Step 4: Roadmap:** `- [x] worktree ต่องาน (\`scripts/new-task.sh\`, \`docs/engineering/parallel-work.md\`) — เริ่มขนานเมื่อตัวชี้วัดระยะ 0–4 นิ่ง`.
- [ ] **Step 5: Run** — expect PASS and `AGENTS.md` under 60 lines for every render.
- [ ] **Step 6: Commit** `docs: parallel work in worktrees (roadmap phase 6)`

### Task 5: Full verification

- [ ] **Step 1:** `SHARD=core bash tests/render-all.sh <stack>` for typescript, python, dotnet, go, rust (scripts render
  for every stack); `SHARD=ui bash tests/render-all.sh typescript` and `… go` (UI_PORT configs). Expect 0 failures.
- [ ] **Step 2:** `git diff --check main` clean.
- [ ] **Step 3:** Open a PR with the render-all output summary.

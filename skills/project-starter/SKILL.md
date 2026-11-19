---
name: project-starter
description: Scaffold a new agent-ready project from the ProjectStarter template (TypeScript, Python, C#/.NET, Go or Rust; Claude Code and/or Codex) with AGENTS.md, strict type/lint/architecture guardrails, CI ratchet, optional CODEOWNERS, risk tiers and docs. Use when the user wants to start, create, bootstrap or scaffold a new project/repo, or add these guardrails to an empty folder.
---

# Project Starter

Creates a project whose rules are enforced by tools (types, lint, architecture checks, CI ratchet, and CODEOWNERS when an owner is given)
instead of prose. Files are rendered by **Copier** so the result is deterministic and can later be updated with
`copier update`. Your job is the judgment part: ask, run the generator, fill in what only the human knows, verify.

## 1. Find the template

The template is the ProjectStarter repository (it contains `copier.yml`). Resolve `TEMPLATE` in this order:

1. `$PROJECT_STARTER_TEMPLATE` if set (local path or git URL).
2. The first line of `template-path.txt` next to this `SKILL.md` (written by `scripts/install-skill.sh`).
3. The repository that contains this skill: two directories above this `SKILL.md`, if it has `copier.yml`.
4. Otherwise ask the user for the path or git URL.

Use an **absolute** path or a git URL so `copier update` works later.

## 2. Ask (one short message, offer the defaults)

| Answer | Values | Default |
|---|---|---|
| `project_name` | letters, digits, `-`, `_`; starts with a letter | — |
| `project_description` | one sentence: who uses it to do what | — |
| `stack` | `typescript`, `python`, `dotnet`, `go`, `rust` | — |
| `agent_tools` | any of `claude`, `codex` | both |
| `guardrail_owner` | optional: `@user` or `@org/team` for `.github/CODEOWNERS` | empty = no CODEOWNERS |
| `risk_paths` | tier-3 paths that always need owner review | `[auth/, payments/, migrations/, infra/]` |
| `datastores` | any of `postgres`, `mysql` or `mariadb` (not both), `sqlserver` (Developer edition for dev/test), `oracle` (Oracle Database Free), `mongodb` (also Atlas via mongodb+srv), `dynamodb` (DynamoDB Local for dev/test), `cosmosdb` (Cosmos DB emulator for dev/test), `s3` (S3 API: AWS S3 or MinIO; S3Mock locally), `redis`: adapters behind the existing port, migrations, Testcontainers integration tests | `[]`; add only what the user asked for, e.g. `-d 'datastores=["postgres"]'` |
| `http_api` | serve the use case over HTTP (Hono / FastAPI / ASP.NET Core / Go net/http / axum) with Playwright API tests and, with `containerize`, an OWASP ZAP baseline scan | `false`; `true` when the user builds a web service or API |
| `frontend` | `none`; TypeScript: `react`, `vue` (Vite), `nextjs`, `angular` or `react-native` (Expo; checks run on its web build); Python, .NET, Go, Rust: `ssr` (Jinja2, Razor Pages, `html/template`, askama): UI as a driving adapter, Playwright + axe browser tests (Node.js needed), strict CSP | `none` |
| `containerize` | Dockerfile (multi-stage, non-root), `compose.yaml`, hadolint and a container CI job | `true`; pass `false` for libraries or when the user does not deploy containers |
| destination | folder to create | `./<project_name>` |

Do not guess the stack or the owner; if the user does not name an owner, leave it empty (no CODEOWNERS is generated). If the destination exists and is not empty, ask before writing into it.

## 3. Check tools

- Always: `git`, `bash`, and `uv` (Copier runs through `uvx`; install uv from https://docs.astral.sh/uv/ if missing).
- `typescript`: Node.js ≥ 22.12 and npm. `python`: uv (Python is fetched by uv). `dotnet`: .NET SDK 10. `go`: Go ≥ 1.26. `rust`: rustup and `cargo install cargo-deny` (Node.js too when `http_api`). Any stack with `frontend=ssr` also needs Node.js (Playwright + axe in `e2e-ui/`).

Report missing tools and stop; do not install system tools without the user's approval.

## 4. Generate

```bash
uvx copier copy --trust --defaults \
  -d project_name=<name> -d "project_description=<sentence>" -d stack=<stack> \
  -d 'agent_tools=["claude","codex"]' \
  -d 'risk_paths=["auth/","payments/","migrations/","infra/"]' \
  "$TEMPLATE" <destination>
```

Add `-d "guardrail_owner=<@user or @org/team>"` only when the user gave an owner.

`--trust` is needed because the template uses computed values. Then initialise git if the folder is not a repository:
`git init -b main`.

## 5. Install and verify (evidence, not claims)

Run inside the destination, using the commands the generated `AGENTS.md` lists:

| Stack | Install | Verify |
|---|---|---|
| typescript | `npm install` | `npm run verify` |
| python | `uv sync` | `uv run pyright && uv run ruff check . && uv run ruff format --check . && uv run lint-imports && uv run pytest` |
| dotnet | `dotnet restore` | `dotnet build && dotnet format --verify-no-changes --no-restore && dotnet test --no-build` |
| go | `go mod tidy` | `go vet ./... && go tool golangci-lint run && go test ./...` |
| rust | `cargo fetch` | `cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && bash ci/check-layers.sh && cargo test --workspace` |

If verification fails, fix the cause in the generated project (never loosen a guardrail config) and report what
you changed. Show the final output lines as evidence.

## 6. Fill in what only the human knows

Draft these with the user — do not invent domain facts:

- `docs/feature-map.md`: replace the `example` row with the real first features (ID, entry point, risk tier).
- `docs/risk-tiers.md`: the team's definition of "revert".
- Remove the sample `export-job` code once the first real feature exists (it is there to show the layering).

Do **not** expand `AGENTS.md` with rules; new rules go to the lowest layer that can enforce them
(`docs/engineering/where-rules-live.md`). Keep it under 60 lines.

## 7. Hand over

Tell the user, briefly:

- what was generated and the verify result;
- GitHub settings only they can turn on: branch protection on `main`, required status check `ci / verify`,
  and "Require review from Code Owners" if CODEOWNERS was generated (otherwise: it can be added later by
  running `uvx copier update --trust` and answering `guardrail_owner`);
- next phase in `docs/roadmap.md` (phase 3: correction records when an agent repeats a mistake);
- to pull later template improvements: `uvx copier update --trust` inside the project.

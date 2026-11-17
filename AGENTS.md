# Repository Guidelines

## Project Structure

ProjectStarter is a Copier template for agent-ready projects. See `README.md` for the layout and `CLAUDE.md` for details.

- `copier.yml` — questions and per-stack facts (`cmd`, `stk`)
- `template/` — files rendered into new projects (conditional file names select stack and agent tools)
- `skills/project-starter/` — portable `SKILL.md` for Claude Code and Codex
- `.claude-plugin/` — Claude Code plugin and marketplace manifests
- `tests/render-all.sh` — end-to-end template test
- `docs/combined.md` — source research and playbook (Thai)

## Build, Test, and Development Commands

Requires `git`, `bash`, `uv`; Node.js ≥ 22.12 (TypeScript) and .NET SDK 10 (.NET) to test those stacks.

- `bash tests/render-all.sh` — render every stack × agent combination, verify each, and check that seeded violations are rejected
- `bash tests/render-all.sh <typescript|python|dotnet>` — one stack
- `uvx copier copy --trust --defaults -d project_name=demo -d stack=python . <dest>` — render one project
- `git diff --check` — whitespace errors

## Coding Style

- Commands and stack facts live once in `copier.yml` (`cmd`, `stk`); templates reference them.
- Generated `AGENTS.md` stays under 60 lines; enforce new rules with tools, not prose.
- Generated shell scripts must run in Git Bash on Windows without `jq`.

## Testing Guidelines

Run `tests/render-all.sh` for every stack a change touches. When a guardrail is added, also add a seeded violation to the test that proves the guardrail rejects it.

## Commit & Pull Request Guidelines

Short, descriptive commit subjects. Pull requests explain the change and motivation, list checks performed, and link relevant issues.

## License

MIT; retain `LICENSE` and check compatibility before adding dependencies or copied material.

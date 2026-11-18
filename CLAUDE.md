# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Copier template that scaffolds agent-ready projects (TypeScript, Python, C#/.NET, Go, Rust; Claude Code and/or Codex), plus a portable skill and a Claude Code plugin wrapper. The source material is `docs/combined.md` (Thai). Layout and usage: `README.md`.

- `copier.yml` — questions plus computed values. `cmd` (verify/lint/test commands) and `stk` (guardrail files, ratchet patterns, layer paths) are the single source of truth per stack; templates read them instead of hard-coding commands.
- `template/` — rendered output (`_subdirectory`). Stack- or tool-specific files use conditional names such as `{% if stack == 'python' %}ruff.toml{% endif %}.jinja`. Only files ending in `.jinja` are rendered; path names are always rendered.
- `skills/project-starter/SKILL.md` — one skill for both Claude Code and Codex; `scripts/install-skill.sh` installs it to `~/.claude/skills` and `~/.agents/skills`.
- `.claude-plugin/` — plugin + marketplace manifests (plugin root is the repo root).

## Commands

Requires `git`, `bash` ≥ 4, `uv`; Node.js ≥ 22.12 for TypeScript renders; .NET SDK 10 for .NET renders; Go ≥ 1.26 for Go renders; rustup and cargo-deny for Rust renders; a running Docker engine for the container and secret-scan checks in `tests/render-all.sh`.

- Render one project: `uvx copier copy --trust --defaults -d project_name=demo -d stack=<typescript|python|dotnet|go|rust> . <dest>` (renders the working tree, including uncommitted changes)
- Full test (renders every stack × agent combination, runs each project's verify, then seeds violations that must be rejected): `bash tests/render-all.sh`
- One stack: `bash tests/render-all.sh python`
- CI (`.github/workflows/render-all.yml`) runs `tests/render-all.sh` for every stack in parallel on each PR into `main`; locally, run only the stacks you changed.
- Validate the plugin manifests: `claude plugin validate .`
- `git diff --check` — whitespace errors

## Rules for changing the template

- Any change under `template/` or `copier.yml` must be followed by `bash tests/render-all.sh` for the affected stacks (CI runs all stacks on the PR).
- Keep the generated `AGENTS.md` under 60 lines (the test checks it). New rules go to the lowest layer that can enforce them (`template/docs/engineering/where-rules-live.md`), not into `AGENTS.md`.
- Generated shell scripts must work in Git Bash on Windows without `jq` (see `template/.../.claude/hooks/_lib.sh`).
- Pin tool versions that have known incompatibilities (TypeScript is held at `~6.0` because typescript-eslint does not support 7.x yet).
- Hook schema: only fields supported by the installed Claude Code version (do not add `onFailure`; it needs v2.1.295+).

## Licensing

The repo is MIT. Keep `LICENSE` intact and check license compatibility before adding dependencies or copying external code. Files rendered from `template/` carry no license; each generated project chooses its own.

## Commits and PRs

Short, descriptive commit subjects. PRs explain the change and motivation, list checks performed (`tests/render-all.sh` output), and link relevant issues.

# Release routine (roadmap phase 6, outer loop)

## Why

Generated `docs/roadmap.md` phase 6 still has one open item: "routine ตอน release ที่ automerge เฉพาะ tier ต่ำ". The
source (`docs/combined.md` layer 8, §1022) describes Tan's outer loop: on every release, cloud agents fuzz the build
"like a real user", open fix PRs and automerge them. It gives no automerge criteria or safeguards, and the source's own
reading is that the outer loop is the last layer to switch on, and only for low risk tiers.

The template today has no release step at all (no tag workflow, no release-only checks). CI on every PR already runs
verify, mutation, integration, the ZAP **baseline** (passive) scan and the UI tests; the weekly cron re-runs CI for new
advisories. Automerge (`automerge` option) acts on tier 0 only, and `ci/risk-tier.sh` gives tier 0 to docs-only PRs.

## Decisions from the user

- **Fix PRs from the routine are always reviewed by a person.** No tier is relaxed for them; automerge stays tier 0
  (docs-only) exactly as today. "Automerge only low tiers" is satisfied by the existing rule, not widened.
- **Approach 3:** a deterministic release check is always generated; an AI agent that exercises the running app like a
  user is a separate copier option, off by default.

## Goals / non-goals / anti-goals

- Goal: on each release tag, run the checks that are too slow or too aggressive for every PR, against the built
  image, and turn every failure into a tracked issue with evidence.
- Goal (opt-in): an agent explores the running release build, reports what it finds as issues, and proposes fixes as
  **draft** PRs that a person reviews.
- Goal: everything the routine opens is labelled, so the team can measure it (phase-6 pass criterion: stability
  metrics do not get worse as volume grows).
- Non-goal: a release process (versioning, changelog, publishing artifacts, deploy, canary). The routine triggers on a
  tag the team already pushes; how they cut releases is theirs.
- Non-goal: changing risk tiers or automerge rules.
- Anti-goal: an agent with write access to the repository, or any routine output reaching `main` without a person.
- Anti-goal: the routine making normal PR CI slower or flakier. Nothing here runs on `pull_request`.

## Approaches

1. Deterministic only: cheap, no secrets, finds only what tests and scanners already cover.
2. Agent only: finds untested problems, but needs an API key, has variable cost, and reads app output (prompt
   injection surface) from the first day.
3. **Deterministic always + agent opt-in (chosen):** teams start with the cheap, predictable part and switch the agent
   on when phases 0–4 are stable, matching the source's "outer loop last".

## Design

### Trigger

`.github/workflows/release-check.yml`, on `push` of tags `v*` and `workflow_dispatch` (input: ref, default the latest
`v*` tag). Never on `pull_request`. *Builder's call:* the tag pattern, kept as one line near the top with a comment.

### Deterministic release check (always generated)

Jobs, each only where the render has the thing it checks:

| Job | What | Rendered when |
|---|---|---|
| `property` | property-based tests at a much higher run count | always (every stack has a property test of the export job) |
| `dast-full` | ZAP **full** (active) scan of the release image, same rules file and hardened container as `ci/dast.sh` | `containerize` and (`serve_http` or `frontend != 'none'`) |
| `report` | for each failed job, open an issue (or comment on the open one for the same job) | always |

- Property run count comes from one environment variable, `PROPERTY_RUNS` (release: 10000; unset: each framework's
  current default, so normal `verify` is unchanged). Each stack's property test reads it: Hypothesis settings profile,
  fast-check `numRuns`, rapid `-rapid.checks`, proptest `PROPTEST_CASES`, FsCheck `MaxTest`. *Builder's call:* exact
  mechanism per stack, as long as unset means unchanged.
- `ci/dast.sh` gains a `--full` mode (ZAP `zap-full-scan.py`), reusing its container hardening, network and
  `.zap/rules.tsv`. Default mode stays the baseline scan. *My call:* `--full` fails only on FAIL-level rules and reports
  WARNs (`-I`), so active rules not yet listed in `rules.tsv` do not make the demo apps fail; rules the team decides
  matter are promoted to FAIL in `rules.tsv`. It is time-capped (`-m` spider minutes and `-T` total minutes, overridable
  by env), so the render-all test stays bounded. Demo apps must pass the FAIL-level rules; no app hardening beyond that
  is in scope.
- Issues: title `release-check: <job> failed on <tag>`, label `release-check`, body with the tag, commit SHA, the
  failing step and a link to the run log. If an open issue with that title prefix and label already exists for the
  job, add a comment instead of a new issue. Permissions: `contents: read`, `issues: write`.
- A failure is never auto-fixed here. A person or an agent picks the issue up through the normal flow
  (`scripts/new-task.sh`, PR, review).

### Agent exploration (copier option `release_fuzz`, default false)

Asked only when `containerize` and `serve_http` (the agent needs a running HTTP service). Help text says to switch it on
after phase 0–4 metrics are stable and that it needs an API key secret.

Two jobs with a hard split between reading untrusted output and writing to the repository:

1. `explore` (no write permissions: `contents: read`, no `issues`/`pull-requests`):
   - builds and starts the release image hardened as in `ci/dast.sh`;
   - runs the agent (Claude Code GitHub Action when `'claude' in agent_tools`, otherwise the Codex action) with a
     fixed prompt file `.github/release-fuzz.md`: exercise the API/UI like a user, within the documented feature map;
     for each problem write a finding (steps, expected, actual, evidence) and, where it can, a patch containing a
     failing test plus a fix that passes the repo's `verify` command;
   - uploads findings (JSON) and patches as a workflow artifact. Nothing else leaves the job.
2. `publish` (no agent, no API key; `issues: write`, `pull-requests: write`, `contents: write`):
   - downloads the artifact, validates it against a fixed schema (bounded counts and sizes; patch paths must not touch
     tier-3 paths from `ci/risk-tier.sh`, otherwise the finding becomes an issue only);
   - opens one issue per finding (label `release-fuzz`) and, for findings with a patch, a **draft** PR from branch
     `release-fix/<tag>-<n>` (label `release-fuzz`), body linking the issue and stating it needs human review.
   - *My call:* the patch is applied onto the default branch's current head (`git apply --3way`), and the PR targets
     the default branch. A patch that does not apply cleanly becomes an issue only, with the patch attached to the run.
   - *My call:* where draft PRs are unavailable (private repos on GitHub Free), it falls back to a normal PR. The label,
     the `release-fix/` automerge skip and the tier rule still keep it from merging without a person.

*My call:* `ci/risk-tier.sh` renders when `automerge or release_fuzz`, so `publish` always has the tier-3 list. When
`automerge` is off there is no automerge workflow, so nothing can merge a routine PR without a person anyway; the docs
list the safeguards that apply to each combination.

Safeguards:

- The automerge workflow skips any PR whose head branch starts with `release-fix/`, in addition to the existing draft
  and tier checks (defence in depth for the user's "always reviewed" decision).
- The API key secret is only exposed to `explore`, which only runs on tag push / dispatch in the repository itself.
- PRs opened with `GITHUB_TOKEN` do not trigger CI. The PR body says so; the reviewer marks it ready and pushes or
  re-runs to get CI. *Builder's call:* whether to document a GitHub App token as the alternative.

### Docs

- `docs/engineering/release-routine.md` (Thai): what runs on a tag, how to read the issues, how to switch on
  `release_fuzz` (`copier update`), the secret it needs, and the safeguards.
- `docs/roadmap.md`: tick the phase-6 item, pointing at the doc; keep "(PR แก้บั๊กผ่าน review คนเสมอ)" in the line.
- `docs/risk-tiers.md` automerge section: one line that routine PRs are never automerged.
- `where-rules-live.md`: a row "PR จาก release routine ต้องผ่านคน → Workflow (automerge skips `release-fix/`)".
- `AGENTS.md`: no new line unless it stays under 60 lines and an agent needs it (it does not: agents meet the routine
  through issues).

## Tests (`tests/render-all.sh`)

- Every render: `release-check.yml` exists and parses as YAML; it has no `pull_request` trigger; jobs match the render
  (no `dast-full` without a container).
- Property knob: run the stack's property test with `PROPERTY_RUNS` set to a small and a large value and show the
  count is honoured (e.g. a test-only counter or the framework's own statistics output); unset leaves `verify` as is.
- `ci/dast.sh --full` against the demo image in the container shard (where Docker runs already), with a short time cap.
- `release_fuzz=true` render (Claude, and Codex-only): both jobs present; `explore` has no write permission;
  `publish` has no secret reference; the prompt file exists.
- `publish` validator: a script (`ci/release-fuzz-publish.sh` or similar) tested with fixture artifacts — valid
  finding → issue + PR calls; patch touching a tier-3 path → issue only; oversize/malformed → rejected. `gh` is stubbed.
- Automerge: a `release-fix/` head branch is skipped (test the condition the workflow uses).

## Left to the builder

The exact property-run mechanism per stack, the artifact schema, the prompt wording, action versions (pin them), the
issue de-duplication query, and the job timeouts.

# Acceptance tests (protected)

Tests here encode the spec (`docs/specs/<feature-id>.md`) and are owned by the guardrail owner (`.github/CODEOWNERS`, when configured).

- Agents must not edit or delete files here. If a test contradicts the spec or the task, stop and report the conflict.
- Add a test here from the spec's acceptance criteria **before** implementing a tier 2–3 feature.

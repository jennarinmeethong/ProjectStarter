-- Migrations are append-only: never edit or delete a merged file; add a new numbered file instead
-- (ci/guardrail-ratchet.sh enforces this). See docs/adr/0003-datastores.md.
CREATE TABLE export_artifacts (
    artifact_key TEXT PRIMARY KEY,
    job_id TEXT NOT NULL,
    body TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX export_artifacts_job_id_idx ON export_artifacts (job_id);

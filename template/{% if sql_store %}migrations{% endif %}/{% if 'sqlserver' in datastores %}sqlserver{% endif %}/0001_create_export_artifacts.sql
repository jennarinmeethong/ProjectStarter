-- SQL Server schema. Migrations are append-only: never edit or delete a merged file;
-- add a new numbered file instead (ci/guardrail-ratchet.sh enforces this).
-- See docs/adr/0003-datastores.md.
CREATE TABLE export_artifacts (
    artifact_key NVARCHAR(255) NOT NULL PRIMARY KEY,
    job_id NVARCHAR(64) NOT NULL,
    body NVARCHAR(MAX) NOT NULL,
    created_at DATETIME2 NOT NULL DEFAULT sysutcdatetime()
);

CREATE INDEX export_artifacts_job_id_idx ON export_artifacts (job_id);

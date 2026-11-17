-- MySQL/MariaDB schema. Migrations are append-only: never edit or delete a merged file;
-- add a new numbered file instead (ci/guardrail-ratchet.sh enforces this).
-- See docs/adr/0003-datastores.md.
CREATE TABLE export_artifacts (
    artifact_key VARCHAR(255) PRIMARY KEY,
    job_id VARCHAR(64) NOT NULL,
    body LONGTEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT current_timestamp
);

CREATE INDEX export_artifacts_job_id_idx ON export_artifacts (job_id);

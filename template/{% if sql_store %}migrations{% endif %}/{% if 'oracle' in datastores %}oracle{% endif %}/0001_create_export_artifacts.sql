-- Oracle schema. Migrations are append-only: never edit or delete a merged file;
-- add a new numbered file instead (ci/guardrail-ratchet.sh enforces this).
-- See docs/adr/0003-datastores.md.
CREATE TABLE export_artifacts (
    artifact_key VARCHAR2(255) NOT NULL PRIMARY KEY,
    job_id VARCHAR2(64) NOT NULL,
    -- BODY is non-reserved in Oracle SQL; the column name matches the other stores.
    body CLOB NOT NULL, -- noqa: RF04
    created_at TIMESTAMP DEFAULT systimestamp NOT NULL
);

CREATE INDEX export_artifacts_job_id_idx ON export_artifacts (job_id);

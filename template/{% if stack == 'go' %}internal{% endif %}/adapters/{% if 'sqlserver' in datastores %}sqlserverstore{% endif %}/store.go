// Package sqlserverstore is an ArtifactStore adapter on SQL Server. Schema: migrations/sqlserver/.
// Queries are always parameterised (@name), never built from strings (ADR 0003).
package sqlserverstore

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"strings"

	// Registers the "sqlserver" database/sql driver.
	_ "github.com/microsoft/go-mssqldb"
)

const (
	// HOLDLOCK makes MERGE an atomic upsert under concurrency.
	upsertSQL = `MERGE export_artifacts WITH (HOLDLOCK) AS target
USING (SELECT @key AS artifact_key, @job AS job_id, @body AS body) AS source
ON target.artifact_key = source.artifact_key
WHEN MATCHED THEN UPDATE SET body = source.body
WHEN NOT MATCHED THEN INSERT (artifact_key, job_id, body) VALUES (source.artifact_key, source.job_id, source.body);`
	readSQL = `SELECT body FROM export_artifacts WHERE artifact_key = @key`
)

// Store keeps artifacts in the export_artifacts table.
type Store struct {
	db *sql.DB
}

// Open connects to sqlserver://user:pass@host:port/db[?trustServerCertificate=true] or a go-mssqldb connection string.
func Open(ctx context.Context, connection string) (*Store, error) {
	dsn, err := toDSN(connection)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlserver", dsn)
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}
	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("connect: %w", err)
	}
	return &Store{db: db}, nil
}

// Save upserts the content under exports/<jobID>.csv.
func (s *Store) Save(ctx context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	_, err := s.db.ExecContext(ctx, upsertSQL, sql.Named("key", key), sql.Named("job", jobID), sql.Named("body", content))
	if err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	var body string
	if err := s.db.QueryRowContext(ctx, readSQL, sql.Named("key", key)).Scan(&body); err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	return body, nil
}

// Close closes the connection pool.
func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return fmt.Errorf("close sqlserver: %w", err)
	}
	return nil
}

// toDSN moves the database from the URL path (where go-mssqldb expects an instance name) to the query.
func toDSN(connection string) (string, error) {
	if !strings.HasPrefix(connection, "sqlserver://") {
		return connection, nil
	}
	parsed, err := url.Parse(connection)
	if err != nil {
		return "", fmt.Errorf("parse sqlserver url: %w", err)
	}
	query := parsed.Query()
	if database := strings.TrimPrefix(parsed.Path, "/"); database != "" {
		query.Set("database", database)
		parsed.Path = ""
	}
	if !query.Has("encrypt") {
		query.Set("encrypt", "true")
	}
	parsed.RawQuery = query.Encode()
	return parsed.String(), nil
}

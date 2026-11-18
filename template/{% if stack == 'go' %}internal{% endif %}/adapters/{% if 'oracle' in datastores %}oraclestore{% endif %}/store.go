// Package oraclestore is an ArtifactStore adapter on Oracle Database (go-ora, pure Go). Schema: migrations/oracle/.
// Values are always bound by name (:name), never built into SQL (ADR 0003).
package oraclestore

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"strconv"
	"strings"

	go_ora "github.com/sijms/go-ora/v2"
)

const (
	upsertSQL = `MERGE INTO export_artifacts t
USING (SELECT :artifact_key AS artifact_key, :job_id AS job_id FROM dual) s
ON (t.artifact_key = s.artifact_key)
WHEN MATCHED THEN UPDATE SET t.body = :body
WHEN NOT MATCHED THEN INSERT (artifact_key, job_id, body) VALUES (s.artifact_key, s.job_id, :body)`
	readSQL = `SELECT body FROM export_artifacts WHERE artifact_key = :artifact_key`
)

// Store keeps artifacts in the export_artifacts table.
type Store struct {
	db *sql.DB
}

// Open connects to oracle://user:password@host:port/service.
func Open(ctx context.Context, connection string) (*Store, error) {
	dsn, err := toDSN(connection)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("oracle", dsn)
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
	_, err := s.db.ExecContext(ctx, upsertSQL,
		sql.Named("artifact_key", key),
		sql.Named("job_id", jobID),
		sql.Named("body", go_ora.Clob{String: content, Valid: true}))
	if err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	var body go_ora.Clob
	if err := s.db.QueryRowContext(ctx, readSQL, sql.Named("artifact_key", key)).Scan(&body); err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	return body.String, nil
}

// Close closes the connection pool.
func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return fmt.Errorf("close oracle: %w", err)
	}
	return nil
}

func toDSN(connection string) (string, error) {
	if !strings.HasPrefix(connection, "oracle://") {
		return connection, nil
	}
	parsed, err := url.Parse(connection)
	if err != nil {
		return "", fmt.Errorf("parse oracle url: %w", err)
	}
	port := 1521
	if p := parsed.Port(); p != "" {
		if port, err = strconv.Atoi(p); err != nil {
			return "", fmt.Errorf("parse oracle port: %w", err)
		}
	}
	password, _ := parsed.User.Password()
	service := strings.TrimPrefix(parsed.Path, "/")
	return go_ora.BuildUrl(parsed.Hostname(), port, service, parsed.User.Username(), password, nil), nil
}

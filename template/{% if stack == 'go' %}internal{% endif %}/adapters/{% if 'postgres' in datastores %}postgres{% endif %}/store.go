// Package postgres is an ArtifactStore adapter on PostgreSQL. Schema: migrations/0001_create_export_artifacts.sql.
// Queries are always parameterised ($1, $2 ...), never built from strings (ADR 0003).
package postgres

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	upsertSQL = `INSERT INTO export_artifacts (artifact_key, job_id, body) VALUES ($1, $2, $3)
ON CONFLICT (artifact_key) DO UPDATE SET body = EXCLUDED.body`
	readSQL = `SELECT body FROM export_artifacts WHERE artifact_key = $1`
)

// Store keeps artifacts in the export_artifacts table.
type Store struct {
	pool *pgxpool.Pool
}

// Open connects to url (postgresql://user:pass@host:port/db).
func Open(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	return &Store{pool: pool}, nil
}

// Save upserts the content under exports/<jobID>.csv.
func (s *Store) Save(ctx context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	if _, err := s.pool.Exec(ctx, upsertSQL, key, jobID, content); err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	var body string
	if err := s.pool.QueryRow(ctx, readSQL, key).Scan(&body); err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	return body, nil
}

// Close releases the connection pool.
func (s *Store) Close() { s.pool.Close() }

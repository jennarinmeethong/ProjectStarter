// Package mysqlstore is an ArtifactStore adapter on MySQL or MariaDB. Schema: migrations/mysql/.
// Queries are always parameterised (?), never built from strings (ADR 0003).
package mysqlstore

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"strings"

	"github.com/go-sql-driver/mysql"
)

const (
	upsertSQL = `INSERT INTO export_artifacts (artifact_key, job_id, body) VALUES (?, ?, ?)
ON DUPLICATE KEY UPDATE body = VALUES(body)`
	readSQL = `SELECT body FROM export_artifacts WHERE artifact_key = ?`
)

// Store keeps artifacts in the export_artifacts table.
type Store struct {
	db *sql.DB
}

// Open connects to a URL (mysql://user:pass@host:port/db) or a go-sql-driver DSN (user:pass@tcp(host:port)/db).
func Open(ctx context.Context, connection string) (*Store, error) {
	dsn, err := toDSN(connection)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("mysql", dsn)
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
	if _, err := s.db.ExecContext(ctx, upsertSQL, key, jobID, content); err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	var body string
	if err := s.db.QueryRowContext(ctx, readSQL, key).Scan(&body); err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	return body, nil
}

// Close closes the connection pool.
func (s *Store) Close() error {
	if err := s.db.Close(); err != nil {
		return fmt.Errorf("close mysql: %w", err)
	}
	return nil
}

func toDSN(connection string) (string, error) {
	if !strings.HasPrefix(connection, "mysql://") {
		return connection, nil
	}
	parsed, err := url.Parse(connection)
	if err != nil {
		return "", fmt.Errorf("parse mysql url: %w", err)
	}
	config := mysql.NewConfig()
	config.Net = "tcp"
	config.Addr = parsed.Host
	if parsed.Port() == "" {
		config.Addr += ":3306"
	}
	config.User = parsed.User.Username()
	config.Passwd, _ = parsed.User.Password()
	config.DBName = strings.TrimPrefix(parsed.Path, "/")
	return config.FormatDSN(), nil
}

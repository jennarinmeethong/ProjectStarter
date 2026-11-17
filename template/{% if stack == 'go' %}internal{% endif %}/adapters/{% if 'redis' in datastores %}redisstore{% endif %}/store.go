// Package redisstore is an ArtifactStore adapter on Redis. It suits short-lived artifacts; set a TTL or use
// PostgreSQL for durable storage.
package redisstore

import (
	"context"
	"fmt"

	"github.com/redis/go-redis/v9"
)

// Store keeps artifacts as Redis strings.
type Store struct {
	client *redis.Client
}

// Open connects to url (redis://user:pass@host:port/db, rediss:// for TLS) and checks the connection.
func Open(ctx context.Context, url string) (*Store, error) {
	options, err := redis.ParseURL(url)
	if err != nil {
		return nil, fmt.Errorf("parse redis url: %w", err)
	}
	client := redis.NewClient(options)
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("connect: %w", err)
	}
	return &Store{client: client}, nil
}

// Save stores the content under exports/<jobID>.csv.
func (s *Store) Save(ctx context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	if err := s.client.Set(ctx, key, content, 0).Err(); err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	content, err := s.client.Get(ctx, key).Result()
	if err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	return content, nil
}

// Close closes the client.
func (s *Store) Close() error {
	if err := s.client.Close(); err != nil {
		return fmt.Errorf("close redis: %w", err)
	}
	return nil
}

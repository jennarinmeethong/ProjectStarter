// Package inmemory is an ArtifactStore adapter that keeps artifacts in memory (tests, demos).
package inmemory

import (
	"context"
	"errors"
	"sync"
)

// ErrNotFound is returned by Read for an unknown key.
var ErrNotFound = errors.New("artifact not found")

// Store keeps artifacts in a map. It is safe for concurrent use.
type Store struct {
	mu    sync.Mutex
	files map[string]string
}

// New returns an empty store.
func New() *Store { return &Store{files: map[string]string{}} }

// Save stores the content under exports/<jobID>.csv.
func (s *Store) Save(_ context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	s.mu.Lock()
	defer s.mu.Unlock()
	s.files[key] = content
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(_ context.Context, key string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	content, ok := s.files[key]
	if !ok {
		return "", ErrNotFound
	}
	return content, nil
}

// Package domain holds export job states, invariants and transitions. It performs no I/O and imports
// only the standard library (ADR 0001).
package domain

import (
	"errors"
	"strings"
)

// ErrBlankArtifactKey is returned when a running job is completed without an artifact key.
var ErrBlankArtifactKey = errors.New("export completion requires an artifact key")

// ExportJob is a closed set of states. Illegal states are unrepresentable: only a running job can
// complete, and a ready job always has an artifact key. gochecksumtype makes every type switch over
// ExportJob handle all four states.
//
//sumtype:decl
type ExportJob interface {
	ID() string
	exportJob()
}

// Queued is a job waiting to start.
type Queued struct{ id string }

// Running is a job in progress.
type Running struct{ id string }

// Ready is a finished job with its artifact key.
type Ready struct {
	id          string
	artifactKey string
}

// Failed is a job that stopped with a reason.
type Failed struct {
	id     string
	reason string
}

// NewQueued creates a queued job.
func NewQueued(id string) Queued { return Queued{id: id} }

// NewFailed creates a failed job.
func NewFailed(id, reason string) Failed { return Failed{id: id, reason: reason} }

// ID returns the job id.
func (j Queued) ID() string { return j.id }

// ID returns the job id.
func (j Running) ID() string { return j.id }

// ID returns the job id.
func (j Ready) ID() string { return j.id }

// ID returns the job id.
func (j Failed) ID() string { return j.id }

// ArtifactKey returns where the export was stored.
func (j Ready) ArtifactKey() string { return j.artifactKey }

// Reason explains why the job failed.
func (j Failed) Reason() string { return j.reason }

func (Queued) exportJob()  {}
func (Running) exportJob() {}
func (Ready) exportJob()   {}
func (Failed) exportJob()  {}

// Start moves a queued job to running.
func Start(job Queued) Running { return Running(job) }

// Complete moves a running job to ready. The artifact key must not be blank.
func Complete(job Running, artifactKey string) (Ready, error) {
	if strings.TrimSpace(artifactKey) == "" {
		return Ready{}, ErrBlankArtifactKey
	}
	return Ready{id: job.id, artifactKey: artifactKey}, nil
}

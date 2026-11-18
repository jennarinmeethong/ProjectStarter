// Package cosmosstore is an ArtifactStore adapter on Azure Cosmos DB (NoSQL API). Items are point
// reads/writes by id; queries, when added, take values as @parameters, never inline (ADR 0003).
package cosmosstore

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/data/azcosmos"
)

const containerName = "export_artifacts"

type item struct {
	ID    string `json:"id"`
	JobID string `json:"job_id"`
	Body  string `json:"body"`
}

// Store keeps artifacts in one Cosmos DB container partitioned by /id.
type Store struct {
	items *azcosmos.ContainerClient
}

// Open connects with an account key.
func Open(endpoint, key, database string) (*Store, error) {
	client, err := newClient(endpoint, key)
	if err != nil {
		return nil, err
	}
	items, err := client.NewContainer(database, containerName)
	if err != nil {
		return nil, fmt.Errorf("cosmos container: %w", err)
	}
	return &Store{items: items}, nil
}

func newClient(endpoint, key string) (*azcosmos.Client, error) {
	cred, err := azcosmos.NewKeyCredential(key)
	if err != nil {
		return nil, fmt.Errorf("cosmos key: %w", err)
	}
	client, err := azcosmos.NewClientWithKey(endpoint, cred, nil)
	if err != nil {
		return nil, fmt.Errorf("cosmos client: %w", err)
	}
	return client, nil
}

// EnsureContainer creates the database and container when missing. Local use only: real accounts get them
// from infrastructure as code.
func EnsureContainer(ctx context.Context, endpoint, key, database string) error {
	client, err := newClient(endpoint, key)
	if err != nil {
		return err
	}
	_, err = client.CreateDatabase(ctx, azcosmos.DatabaseProperties{ID: database}, nil)
	if err != nil && !hasStatus(err, http.StatusConflict) {
		return fmt.Errorf("create database: %w", err)
	}
	db, err := client.NewDatabase(database)
	if err != nil {
		return fmt.Errorf("cosmos database: %w", err)
	}
	props := azcosmos.ContainerProperties{
		ID:                     containerName,
		PartitionKeyDefinition: azcosmos.PartitionKeyDefinition{Paths: []string{"/id"}, Kind: azcosmos.PartitionKeyKindHash},
	}
	if _, err := db.CreateContainer(ctx, props, nil); err != nil && !hasStatus(err, http.StatusConflict) {
		return fmt.Errorf("create container: %w", err)
	}
	return nil
}

// itemID maps the artifact key to a Cosmos id, which cannot contain "/".
func itemID(key string) string {
	return strings.ReplaceAll(key, "/", "|")
}

func hasStatus(err error, status int) bool {
	var response *azcore.ResponseError
	return errors.As(err, &response) && response.StatusCode == status
}

// Save upserts the content under exports/<jobID>.csv.
func (s *Store) Save(ctx context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	id := itemID(key)
	doc, err := json.Marshal(item{ID: id, JobID: jobID, Body: content})
	if err != nil {
		return "", fmt.Errorf("encode %s: %w", key, err)
	}
	if _, err := s.items.UpsertItem(ctx, azcosmos.NewPartitionKeyString(id), doc, nil); err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	id := itemID(key)
	response, err := s.items.ReadItem(ctx, azcosmos.NewPartitionKeyString(id), id, nil)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	var found item
	if err := json.Unmarshal(response.Value, &found); err != nil {
		return "", fmt.Errorf("decode %s: %w", key, err)
	}
	return found.Body, nil
}

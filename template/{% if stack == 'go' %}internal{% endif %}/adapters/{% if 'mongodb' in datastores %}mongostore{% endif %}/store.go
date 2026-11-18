// Package mongostore is an ArtifactStore adapter on MongoDB (also Atlas: pass a mongodb+srv:// URL).
// Filters are bson documents with plain values, never parsed from strings (ADR 0003).
package mongostore

import (
	"context"
	"fmt"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/x/mongo/driver/connstring"
)

type artifact struct {
	Key   string `bson:"_id"`
	JobID string `bson:"job_id"`
	Body  string `bson:"body"`
}

// Store keeps artifacts in the export_artifacts collection.
type Store struct {
	client    *mongo.Client
	artifacts *mongo.Collection
}

// Open connects to a mongodb:// URL (the database comes from its path) and ensures the indexes exist.
func Open(ctx context.Context, url string) (*Store, error) {
	parsed, err := connstring.ParseAndValidate(url)
	if err != nil {
		return nil, fmt.Errorf("parse mongodb url: %w", err)
	}
	database := parsed.Database
	if database == "" {
		database = "app"
	}
	client, err := mongo.Connect(options.Client().ApplyURI(url).SetMaxPoolSize(5))
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	artifacts := client.Database(database).Collection("export_artifacts")
	byJob := mongo.IndexModel{Keys: bson.D{{Key: "job_id", Value: 1}}}
	if _, err := artifacts.Indexes().CreateOne(ctx, byJob); err != nil {
		_ = client.Disconnect(ctx)
		return nil, fmt.Errorf("create index: %w", err)
	}
	return &Store{client: client, artifacts: artifacts}, nil
}

// Save upserts the content under exports/<jobID>.csv.
func (s *Store) Save(ctx context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	doc := artifact{Key: key, JobID: jobID, Body: content}
	_, err := s.artifacts.ReplaceOne(ctx, bson.D{{Key: "_id", Value: key}}, doc, options.Replace().SetUpsert(true))
	if err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	var found artifact
	err := s.artifacts.FindOne(ctx, bson.D{{Key: "_id", Value: key}}).Decode(&found)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	return found.Body, nil
}

// Close disconnects the client.
func (s *Store) Close(ctx context.Context) error {
	if err := s.client.Disconnect(ctx); err != nil {
		return fmt.Errorf("close mongodb: %w", err)
	}
	return nil
}

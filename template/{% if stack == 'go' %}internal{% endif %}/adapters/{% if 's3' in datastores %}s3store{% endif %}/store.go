// Package s3store is an ArtifactStore adapter on the S3 API (AWS S3, MinIO, or any S3-compatible store).
// The artifact key is the object key (ADR 0003).
package s3store

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// Store keeps artifacts as objects in one bucket.
type Store struct {
	client *s3.Client
	bucket string
}

// Open creates a client. Set endpoint for MinIO or a local server; omit it for AWS S3, where the SDK's default
// region and credential chain apply.
func Open(ctx context.Context, bucket, endpoint string) (*Store, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}
	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		if endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
			// Path-style addressing: MinIO and local servers have no per-bucket DNS names.
			o.UsePathStyle = true
		}
	})
	return &Store{client: client, bucket: bucket}, nil
}

// Save writes the content to exports/<jobID>.csv, replacing any earlier object.
func (s *Store) Save(ctx context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(s.bucket),
		Key:         aws.String(key),
		Body:        strings.NewReader(content),
		ContentType: aws.String("text/csv"),
	})
	if err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key)})
	if err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	defer func() { _ = out.Body.Close() }()
	body, err := io.ReadAll(out.Body)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	return string(body), nil
}

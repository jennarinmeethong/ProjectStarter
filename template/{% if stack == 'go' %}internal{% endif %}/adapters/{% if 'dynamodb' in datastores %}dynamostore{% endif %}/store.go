// Package dynamostore is an ArtifactStore adapter on DynamoDB. Table definition: infra/dynamodb/.
// Items are addressed by key only; values never go into expression strings (ADR 0003).
package dynamostore

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

// ErrNotFound is returned by Read when no artifact is stored under the key.
var ErrNotFound = errors.New("artifact not found")

// Store keeps artifacts in one DynamoDB table.
type Store struct {
	client *dynamodb.Client
	table  string
}

// Open creates a client. Set endpoint for DynamoDB Local; on AWS the SDK's default region and credential
// chain apply.
func Open(ctx context.Context, table, endpoint string) (*Store, error) {
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}
	client := dynamodb.NewFromConfig(cfg, func(o *dynamodb.Options) {
		if endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
		}
	})
	return &Store{client: client, table: table}, nil
}

// Save puts the content under exports/<jobID>.csv, replacing any earlier item.
func (s *Store) Save(ctx context.Context, jobID, content string) (string, error) {
	key := "exports/" + jobID + ".csv"
	_, err := s.client.PutItem(ctx, &dynamodb.PutItemInput{
		TableName: aws.String(s.table),
		Item: map[string]types.AttributeValue{
			"artifact_key": &types.AttributeValueMemberS{Value: key},
			"job_id":       &types.AttributeValueMemberS{Value: jobID},
			"body":         &types.AttributeValueMemberS{Value: content},
		},
	})
	if err != nil {
		return "", fmt.Errorf("save %s: %w", key, err)
	}
	return key, nil
}

// Read returns the content stored under key.
func (s *Store) Read(ctx context.Context, key string) (string, error) {
	out, err := s.client.GetItem(ctx, &dynamodb.GetItemInput{
		TableName:      aws.String(s.table),
		Key:            map[string]types.AttributeValue{"artifact_key": &types.AttributeValueMemberS{Value: key}},
		ConsistentRead: aws.Bool(true),
	})
	if err != nil {
		return "", fmt.Errorf("read %s: %w", key, err)
	}
	body, ok := out.Item["body"].(*types.AttributeValueMemberS)
	if !ok {
		return "", fmt.Errorf("read %s: %w", key, ErrNotFound)
	}
	return body.Value, nil
}

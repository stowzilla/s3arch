# S3arch

Full-text search for DynamoDB on AWS Lambda using SQLite FTS5. Per-owner indexes stored on S3, queried from Lambda `/tmp` with LRU eviction and DynamoDB version tracking.

## Why?

DynamoDB doesn't have native full-text search. OpenSearch/Elasticsearch is expensive and complex for many use cases. S3arch gives you fast, typo-tolerant search with zero infrastructure beyond what you already have (Lambda, S3, DynamoDB).

**How it works:**

```
DynamoDB (source) → Stream → EventBridge Pipe → SQS → Indexer Lambda
                                                         ↓
                                                    SQLite FTS5 DB
                                                         ↓
                                                    S3 (per-owner)
                                                         ↓
                                    Search Lambda ← /tmp cache (LRU)
```

Each owner (user, tenant, account) gets their own SQLite database. The indexer rebuilds it on every change. The searcher downloads it to `/tmp` on first query, then serves subsequent queries from the warm cache until the version changes.

## Installation

```ruby
gem 's3arch'
```

Requires the `sqlite3` native extension available at runtime. On Lambda, use a layer that provides it (e.g., [stowzilla-sqlite3-ruby](https://github.com/stowzilla/stowzilla-sqlite3-ruby)).

## Usage

### Configuration

```ruby
require 's3arch'

S3arch.configure do |c|
  c.from_env!                                    # Reads S3ARCH_* env vars
  c.source_index = 'UserIndex'                   # GSI for owner lookup
  c.owner_key = 'userId'                         # Partition key for owner
  c.searchable_fields = %w[name description tags] # FTS5 indexed fields
  c.metadata_fields = %w[status created_at]       # Stored for filtering (not searched)
  c.record_filter = ->(item) { item['status'] == 'active' }
  c.logger = Logger.new($stdout)
end
```

### Lambda Handlers

**Indexer** (triggered by SQS from DynamoDB Streams):

```ruby
def handler(event:, context:)
  S3arch::Handler.indexer(event)
end
```

**Searcher** (invoked directly or via API Gateway):

```ruby
def handler(event:, context:)
  result = S3arch::Handler.search(event)
  # => { record_ids: ["id1", "id2", ...], search_mode: "fts5" }
end
```

### Search Event Format

```json
{
  "query": "blue chair",
  "owner_ids": ["user-123", "user-456"],
  "filters": { "status": "active" }
}
```

### Manual Indexing

```ruby
indexer = S3arch::Indexer.new
indexer.rebuild("user-123")
```

## Environment Variables

| Variable | Used By | Description |
|----------|---------|-------------|
| `S3ARCH_SOURCE_TABLE` | Indexer | DynamoDB source table name |
| `S3ARCH_SOURCE_INDEX` | Indexer | GSI name for owner lookup (default: `UserIndex`) |
| `S3ARCH_INDEX_BUCKET` | Both | S3 bucket for SQLite index files |
| `S3ARCH_VERSION_TABLE` | Both | DynamoDB version tracking table |

## Infrastructure

A Terraform module is provided at [`terraform/`](./terraform/) that provisions:

- S3 bucket for index storage (with 90-day lifecycle)
- DynamoDB version tracking table (PAY_PER_REQUEST)
- SQS queue + DLQ for the indexer
- EventBridge Pipe (DynamoDB Stream → SQS)

```hcl
module "s3arch" {
  source                  = "github.com/stowzilla/s3arch//terraform"
  app_name                = "myapp"
  environment             = "production"
  source_table_name       = aws_dynamodb_table.items.name
  source_table_arn        = aws_dynamodb_table.items.arn
  source_table_stream_arn = aws_dynamodb_table.items.stream_arn
}
```

Outputs include `indexer_env_vars`, `searcher_env_vars`, `indexer_permissions`, and `searcher_permissions` for easy Lambda configuration.

## Configuration Options

| Option | Default | Description |
|--------|---------|-------------|
| `source_table` | — | DynamoDB table with source records |
| `source_index` | — | GSI name for querying by owner |
| `owner_key` | `"user_id"` | Partition key field for owner lookup |
| `index_bucket` | — | S3 bucket for SQLite files |
| `version_table` | — | DynamoDB table for version tracking |
| `searchable_fields` | `["name", "description"]` | Fields indexed in FTS5 |
| `metadata_fields` | `["status", "created_at"]` | Fields stored for filtering |
| `record_filter` | `->(_) { true }` | Proc to filter records during indexing |
| `owner_extractor` | (extracts from DynamoDB stream image) | Proc to extract owner_id from stream event |
| `version_ttl` | `30` (seconds) | How long to cache version checks |
| `max_results` | `50` | Maximum search results returned |
| `max_cached_dbs` | `20` | Max databases cached in `/tmp` |

## How Search Works

1. **Query arrives** with `owner_ids` and a search string
2. For each owner, check DynamoDB version table (cached for `version_ttl` seconds)
3. If version changed (or first request), download SQLite DB from S3 to `/tmp`
4. Run FTS5 `MATCH` query with prefix matching (`term*`)
5. Apply metadata filters, sort by rank, return record IDs
6. LRU eviction when `/tmp` fills up

## Requirements

- Ruby >= 3.2
- AWS Lambda with `/tmp` storage (recommend 2048MB ephemeral)
- SQLite3 native extension (via Lambda layer)
- DynamoDB table with streams enabled
- S3 bucket for index storage

## License

MIT

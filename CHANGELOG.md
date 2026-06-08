# Changelog

## [0.0.1] - 2025-06-08

### Added

- Initial release
- `S3arch::Indexer` — builds per-owner SQLite FTS5 databases from DynamoDB records
- `S3arch::Searcher` — queries per-owner indexes from Lambda `/tmp` with LRU caching
- `S3arch::Handler` — pre-built Lambda handler methods for indexer and search
- `S3arch::Configuration` — declarative configuration with `from_env!` convenience
- DynamoDB version tracking for cache invalidation
- EventBridge Pipe architecture (DynamoDB Streams → SQS → Indexer Lambda)
- Terraform module for infrastructure provisioning

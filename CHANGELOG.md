# Changelog

## [0.0.2] - 2025-06-08

### Added

- `S3arch::Tokenizer` — pure tokenization class for pre-computing search tokens
- Token-based indexing — indexer reads pre-computed tokens, never raw content
- Incremental updates via `Indexer#apply_changes` (DynamoDB Stream INSERT/MODIFY/REMOVE)
- `Indexer#process_event` — processes SQS events containing DynamoDB stream records
- `Configuration#token_field` — configurable DynamoDB attribute for stored tokens
- `Configuration#searchable_fields` — configurable list of fields to tokenize

### Changed

- `S3arch::Indexer` rewritten to support both full rebuild and incremental updates
- FTS5 contentless DELETE support using stored token values from stream OLD_IMAGE

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

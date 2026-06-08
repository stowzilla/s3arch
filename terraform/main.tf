# S3arch Terraform Module
# Provides the shared infrastructure for s3arch: version table, index bucket, SQS queue,
# and DynamoDB Streams → EventBridge Pipe → SQS wiring.
#
# Usage:
#   module "s3arch" {
#     source       = "../../../gems/s3arch/terraform"
#     app_name     = var.app_name
#     environment  = var.environment
#     source_table_name       = aws_dynamodb_table.inventory.name
#     source_table_arn        = aws_dynamodb_table.inventory.arn
#     source_table_stream_arn = aws_dynamodb_table.inventory.stream_arn
#     common_tags  = local.common_tags
#   }

variable "app_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "source_table_name" {
  description = "DynamoDB table name that has streams enabled"
  type        = string
}

variable "source_table_arn" {
  description = "DynamoDB table ARN (for IAM)"
  type        = string
}

variable "source_table_stream_arn" {
  description = "DynamoDB table stream ARN"
  type        = string
}

variable "common_tags" {
  type    = map(string)
  default = {}
}

# --- S3 bucket for index files ---
resource "aws_s3_bucket" "index" {
  bucket = "${var.app_name}-search-indexes-${var.environment}"
  tags   = var.common_tags
}

resource "aws_s3_bucket_lifecycle_configuration" "index" {
  bucket = aws_s3_bucket.index.id

  rule {
    id     = "expire-old-indexes"
    status = "Enabled"
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 7 }
  }
}

# --- DynamoDB version tracking table ---
resource "aws_dynamodb_table" "versions" {
  name             = "${var.app_name}-${var.environment}-search-indexes"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "userId"

  attribute {
    name = "userId"
    type = "S"
  }

  point_in_time_recovery { enabled = true }
  tags = var.common_tags
}

# --- SQS queue for indexer ---
resource "aws_sqs_queue" "indexer" {
  name                       = "${var.app_name}-${var.environment}-search-indexer"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 86400
  tags                       = var.common_tags
}

resource "aws_sqs_queue" "indexer_dlq" {
  name = "${var.app_name}-${var.environment}-search-indexer-dlq"
  tags = var.common_tags
}

resource "aws_sqs_queue_redrive_policy" "indexer" {
  queue_url = aws_sqs_queue.indexer.id
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.indexer_dlq.arn
    maxReceiveCount     = 3
  })
}

# --- EventBridge Pipe: DynamoDB Stream → SQS ---
resource "aws_iam_role" "pipe" {
  name = "${var.app_name}-${var.environment}-s3arch-pipe"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "pipes.amazonaws.com" }
    }]
  })
  tags = var.common_tags
}

resource "aws_iam_role_policy" "pipe" {
  name = "s3arch-pipe-policy"
  role = aws_iam_role.pipe.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"]
        Resource = var.source_table_stream_arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.indexer.arn
      }
    ]
  })
}

resource "aws_pipes_pipe" "stream_to_indexer" {
  name     = "${var.app_name}-${var.environment}-s3arch"
  role_arn = aws_iam_role.pipe.arn
  source   = var.source_table_stream_arn
  target   = aws_sqs_queue.indexer.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10
      maximum_batching_window_in_seconds = 30
    }
  }

  tags = var.common_tags
}

# --- Outputs for Lambda configuration ---
output "index_bucket_name" {
  value = aws_s3_bucket.index.id
}

output "index_bucket_arn" {
  value = aws_s3_bucket.index.arn
}

output "version_table_name" {
  value = aws_dynamodb_table.versions.name
}

output "version_table_arn" {
  value = aws_dynamodb_table.versions.arn
}

output "indexer_queue_arn" {
  value = aws_sqs_queue.indexer.arn
}

# Convenience: environment variables to pass to both Lambdas
output "indexer_env_vars" {
  value = {
    S3ARCH_SOURCE_TABLE  = var.source_table_name
    S3ARCH_SOURCE_INDEX  = "UserIndex"
    S3ARCH_INDEX_BUCKET  = aws_s3_bucket.index.id
    S3ARCH_VERSION_TABLE = aws_dynamodb_table.versions.name
  }
}

output "searcher_env_vars" {
  value = {
    S3ARCH_INDEX_BUCKET  = aws_s3_bucket.index.id
    S3ARCH_VERSION_TABLE = aws_dynamodb_table.versions.name
  }
}

# Convenience: dispatcher lambda_config permissions for the indexer Lambda
output "indexer_permissions" {
  value = {
    s3_buckets = [{
      bucket_arn  = aws_s3_bucket.index.arn
      permissions = ["s3:PutObject"]
    }]
    dynamodb_tables = [
      { table_arn = var.source_table_arn, permissions = ["dynamodb:Query"], index_names = ["UserIndex"] },
      { table_arn = aws_dynamodb_table.versions.arn, permissions = ["dynamodb:UpdateItem"] }
    ]
    sqs_triggers = [{
      queue_arn                         = aws_sqs_queue.indexer.arn
      batch_size                        = 10
      maximum_batching_window_in_seconds = 30
    }]
  }
}

# Convenience: dispatcher lambda_config permissions for the search Lambda
output "searcher_permissions" {
  value = {
    s3_buckets = [{
      bucket_arn  = aws_s3_bucket.index.arn
      permissions = ["s3:GetObject"]
    }]
    dynamodb_tables = [
      { table_arn = aws_dynamodb_table.versions.arn, permissions = ["dynamodb:GetItem"] }
    ]
  }
}

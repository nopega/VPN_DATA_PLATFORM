# Two buckets, as in the original platform:
#   warehouse -- Iceberg data and metadata, written by Spark, read by Trino,
#                access handed out by Polaris
#   logs      -- Airflow task logs, Spark event logs; disposable
#
# Pods reach both through the S3 gateway endpoint from stage 01: no NAT, no
# per-GB charge.
#
# The account id is in the names because bucket names are global across all
# of AWS; it makes a collision with someone else's bucket impossible.

locals {
  buckets = {
    warehouse = "${var.project_name}-warehouse-${local.account_id}"
    logs      = "${var.project_name}-logs-${local.account_id}"
  }
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = each.value

  # false on purpose: `terraform destroy` fails on a non-empty bucket
  # instead of deleting the warehouse. Empty it deliberately first.
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ACLs off: access is decided only by IAM policies, never by per-object ACLs.
resource "aws_s3_bucket_ownership_controls" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Logs are useful for weeks, not forever. (The original platform designed
# lifecycle rules but never applied them -- BACKLOG item there.)
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.this["logs"].id

  # Only objects larger than 0 bytes expire. Zero-byte "directory" markers
  # stay: Spark refuses to start if spark.eventLog.dir (spark-events/, made
  # by stage 09) does not exist, and it would stop existing 30 days after the
  # last job if the marker expired with the logs.
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {
      object_size_greater_than = 0
    }
    expiration {
      days = var.logs_retention_days
    }
  }

  # Separate rule: S3 does not allow an object-size filter on this action.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

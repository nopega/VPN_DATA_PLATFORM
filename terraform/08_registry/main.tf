# Stage 08 -- what Harbor needs from AWS: a bucket for image layers and an
# identity allowed to use only that bucket.
#
#   docker push ──▶ harbor.nopega.net (internal ALB) ──▶ Harbor registry pod
#                                                        └──▶ s3://<registry bucket>
#   node pulls  ──▶ the same path, from inside the VPC
#
# Harbor itself (the chart) is applied by Argo CD from the apps repository.
#
# WHY AN IAM USER, NOT POD IDENTITY
# ---------------------------------
# Harbor 2.15 bundles distribution 2.8, whose S3 driver builds its own
# credential chain: static keys, environment variables, ~/.aws/credentials,
# EC2 instance role. Neither web identity (IRSA) nor the container credential
# endpoint (Pod Identity) is in it, so a pod identity is never read and pushes
# fail with "NoCredentialProviders". The original platform hit this and
# settled on one access key scoped to one bucket; same here.
#
# The access key is NOT created by Terraform. Terraform would keep the secret
# half in terraform.tfstate, a plain file on the laptop. bootstrap/harbor.sh
# creates it and puts it straight into Secrets Manager.

locals {
  bucket_name = "${var.project_name}-registry-${local.account_id}"
}

# ---------------------------------------------------------------------------
# Bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "registry" {
  bucket = local.bucket_name

  # false on purpose: `terraform destroy` fails on a non-empty bucket instead
  # of deleting every image the platform runs.
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "registry" {
  bucket = aws_s3_bucket.registry.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "registry" {
  bucket = aws_s3_bucket.registry.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "registry" {
  bucket = aws_s3_bucket.registry.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Only abandoned multipart uploads expire. Never the objects: Harbor decides
# what to delete (tag retention + garbage collection), and an S3 rule deleting
# a layer underneath it corrupts an image silently until someone pulls it.
resource "aws_s3_bucket_lifecycle_configuration" "registry" {
  bucket = aws_s3_bucket.registry.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# Identity: one user, this bucket only
# ---------------------------------------------------------------------------

resource "aws_iam_user" "registry" {
  name = "${var.project_name}-harbor-registry"
}

data "aws_iam_policy_document" "registry" {
  statement {
    sid = "Objects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.registry.arn}/*"]
  }

  statement {
    sid = "Bucket"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
    ]
    resources = [aws_s3_bucket.registry.arn]
  }
}

resource "aws_iam_user_policy" "registry" {
  name   = "registry-bucket"
  user   = aws_iam_user.registry.name
  policy = data.aws_iam_policy_document.registry.json
}

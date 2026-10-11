# Stage 09 -- Spark's own AWS identity.
#
# What Spark does NOT get here: the warehouse. Table data and metadata are
# written with short-lived credentials that Polaris vends per table, from its
# storage role (stage 06), after checking the Polaris principal Spark uses
# (bootstrap/spark.sh: principal "etl"). The original platform found this out
# from a failed write naming the Polaris storage role rather than Spark's.
#
# What Spark DOES get: its event logs, the record of every job that the Spark
# history server reads after the driver is gone.
#
#   spark pod ──Pod Identity──▶ vpn-data-platform-spark ──▶ s3://<logs>/spark-events/*
#             ──Polaris (etl)──▶ vended credentials       ──▶ s3://<warehouse>/{bronze,silver,gold}/<table>/*
#
# If a job ever reads raw files from S3 directly (outside the catalog), the
# permission for that prefix goes here -- deliberately not granted ahead of
# time.

resource "aws_iam_role" "spark" {
  name = "${var.project_name}-spark"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "spark_event_logs" {
  name = "spark-event-logs"
  role = aws_iam_role.spark.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EventLogObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [
          "${local.logs_arn}/${var.eventlog_prefix}",
          "${local.logs_arn}/${var.eventlog_prefix}/*",
        ]
      },
      {
        Sid      = "EventLogListing"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
        Resource = local.logs_arn
        Condition = {
          StringLike = { "s3:prefix" = [var.eventlog_prefix, "${var.eventlog_prefix}/*"] }
        }
      },
      {
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = local.logs_arn
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "spark" {
  cluster_name    = var.cluster_name
  namespace       = var.spark_namespace
  service_account = var.spark_service_account
  role_arn        = aws_iam_role.spark.arn
}

# Spark refuses to start when spark.eventLog.dir does not exist, and on S3 a
# "directory" exists only while something is under it. This empty marker
# keeps it existing. It is zero bytes, so the logs bucket's 30-day expiry
# (stage 06, objects larger than 0 bytes) never removes it.
resource "aws_s3_object" "eventlog_dir" {
  bucket  = local.logs_bucket
  key     = "${var.eventlog_prefix}/"
  content = ""
}

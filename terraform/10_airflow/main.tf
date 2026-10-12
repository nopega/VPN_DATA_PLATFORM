# Stage 10 -- Airflow's AWS identity: task logs, nothing else.
#
# With KubernetesExecutor a task's pod is deleted when the task ends, and its
# log file goes with it. Remote logging to S3 is what keeps the log of a
# failed task readable. Airflow orchestrates; it touches no table data, so it
# gets one prefix of the logs bucket and no warehouse access at all.
#
#   airflow pods ──Pod Identity──▶ vpn-data-platform-airflow ──▶ s3://<logs>/airflow/*
#
# The logs bucket's 30-day expiry (stage 06) is the retention; Airflow is
# not configured to delete logs itself.

resource "aws_iam_role" "airflow" {
  name = "${var.project_name}-airflow"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "airflow_logs" {
  name = "airflow-task-logs"
  role = aws_iam_role.airflow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "TaskLogObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${local.logs_arn}/${var.log_prefix}/*"
      },
      {
        Sid      = "TaskLogListing"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.logs_arn
        Condition = {
          StringLike = { "s3:prefix" = [var.log_prefix, "${var.log_prefix}/*"] }
        }
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "airflow" {
  for_each = toset(var.airflow_service_accounts)

  cluster_name    = var.cluster_name
  namespace       = var.airflow_namespace
  service_account = each.value
  role_arn        = aws_iam_role.airflow.arn
}

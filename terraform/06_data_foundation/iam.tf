# How Polaris gets at the warehouse -- the original platform's two-role chain,
# with EKS Pod Identity in place of IRSA:
#
#   polaris pod ──Pod Identity──▶ polaris-service role
#                                     │ sts:AssumeRole (only this one target)
#                                     ▼
#                                 polaris-storage role ──▶ s3://<warehouse>/{bronze,silver,gold}/*
#
# Polaris then hands Spark and Trino short-lived credentials from the storage
# role, narrowed further to the one table being read or written ("credential
# vending"). Spark and Trino therefore need no S3 permissions of their own.

locals {
  warehouse_arn = aws_s3_bucket.this["warehouse"].arn
}

# --- the role the Polaris pod runs as ---------------------------------------

resource "aws_iam_role" "polaris_service" {
  name = "${var.project_name}-polaris-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# Its only permission: become the storage role. No S3 access of its own.
resource "aws_iam_role_policy" "polaris_service_assume_storage" {
  name = "assume-storage-role"
  role = aws_iam_role.polaris_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = aws_iam_role.polaris_storage.arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "polaris" {
  cluster_name    = var.cluster_name
  namespace       = var.polaris_namespace
  service_account = var.polaris_service_account
  role_arn        = aws_iam_role.polaris_service.arn
}

# --- the role that can touch the warehouse ----------------------------------

resource "aws_iam_role" "polaris_storage" {
  name = "${var.project_name}-polaris-storage"

  # Only the Polaris service role may assume it.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.polaris_service.arn }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "polaris_storage_s3" {
  name = "warehouse-medallion-layers"
  role = aws_iam_role.polaris_storage.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ObjectsInMedallionLayers"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [for l in var.medallion_layers : "${local.warehouse_arn}/${l}/*"]
      },
      {
        Sid      = "ListMedallionLayers"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.warehouse_arn
        Condition = {
          StringLike = { "s3:prefix" = [for l in var.medallion_layers : "${l}/*"] }
        }
      },
      {
        # Iceberg and Polaris check the bucket's region before vending.
        Sid      = "BucketLocation"
        Effect   = "Allow"
        Action   = "s3:GetBucketLocation"
        Resource = local.warehouse_arn
      },
    ]
  })
}

output "registry_bucket" {
  description = "Goes into apps/harbor.yaml (persistence.imageChartStorage.s3.bucket)."
  value       = aws_s3_bucket.registry.bucket
}

output "registry_iam_user" {
  description = "bootstrap/harbor.sh creates this user's access key."
  value       = aws_iam_user.registry.name
}

output "warehouse_bucket" {
  value = aws_s3_bucket.this["warehouse"].bucket
}

output "logs_bucket" {
  value = aws_s3_bucket.this["logs"].bucket
}

output "db_endpoint" {
  description = "host:port, private. Reachable from pods and from your Mac over Tailscale."
  value       = aws_db_instance.this.endpoint
}

output "db_address" {
  value = aws_db_instance.this.address
}

output "db_master_secret_arn" {
  description = "Secrets Manager secret holding the master username and password (managed and rotated by RDS)."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "polaris_storage_role_arn" {
  description = "Given to Polaris when the catalog is created: the role it assumes to reach the warehouse."
  value       = aws_iam_role.polaris_storage.arn
}

output "polaris_service_account" {
  value = "${var.polaris_namespace}/${var.polaris_service_account}"
}

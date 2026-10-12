output "airflow_role_arn" {
  value = aws_iam_role.airflow.arn
}

output "remote_base_log_folder" {
  description = "config.logging.remote_base_log_folder in apps/airflow.yaml."
  value       = "s3://${local.logs_bucket}/${var.log_prefix}"
}

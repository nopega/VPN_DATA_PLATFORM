output "spark_role_arn" {
  value = aws_iam_role.spark.arn
}

output "spark_service_account" {
  value = "${var.spark_namespace}/${var.spark_service_account}"
}

output "eventlog_dir" {
  description = "spark.eventLog.dir for every SparkApplication."
  value       = "s3a://${local.logs_bucket}/${var.eventlog_prefix}/"
}

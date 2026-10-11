variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "vpn-data-platform"
}

variable "cluster_name" {
  type    = string
  default = "vpn-data-platform"
}

variable "spark_namespace" {
  description = "Where SparkApplications run (apps repo: workloads/spark)."
  type        = string
  default     = "spark"
}

variable "spark_service_account" {
  description = "Driver and executor pods both run as this ServiceAccount."
  type        = string
  default     = "spark"
}

variable "eventlog_prefix" {
  description = "Prefix in the logs bucket for Spark event logs (read later by the Spark history server)."
  type        = string
  default     = "spark-events"
}

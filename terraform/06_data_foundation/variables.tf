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

variable "medallion_layers" {
  description = <<-EOT
    Top-level prefixes in the warehouse bucket. As in the original platform,
    the S3 path IS the policy key: a namespace bronze.trip.nyc_taxi lives
    under s3://<warehouse>/bronze/trip/nyc_taxi/, and access is granted per
    layer prefix.
  EOT
  type        = list(string)
  default     = ["bronze", "silver", "gold"]
}

variable "polaris_namespace" {
  description = "Kubernetes namespace Polaris will run in (Argo CD Application, next step)."
  type        = string
  default     = "polaris"
}

variable "polaris_service_account" {
  type    = string
  default = "polaris"
}

variable "db_instance_class" {
  description = "db.t4g.micro: 2 vCPU burstable, 1 GiB. Same as the original; ample for two small catalog/metadata databases."
  type        = string
  default     = "db.t4g.micro"
}

variable "logs_retention_days" {
  description = "Airflow task logs and Spark event logs expire after this many days."
  type        = number
  default     = 30
}

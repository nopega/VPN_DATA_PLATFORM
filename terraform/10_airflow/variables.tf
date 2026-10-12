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

variable "airflow_namespace" {
  type    = string
  default = "airflow"
}

variable "airflow_service_accounts" {
  description = <<-EOT
    Every Airflow ServiceAccount that reads or writes task logs. The chart
    makes one per component (release "airflow"): the API server reads logs to
    show them, everything else writes them. Pod Identity matches exact names
    (no wildcard like the original's IRSA trust), so a component the chart
    adds later needs a line here.
  EOT
  type        = list(string)
  default = [
    "airflow-api-server",
    "airflow-scheduler",
    "airflow-dag-processor",
    "airflow-triggerer",
    "airflow-worker",
  ]
}

variable "log_prefix" {
  type    = string
  default = "airflow"
}

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

variable "karpenter_version" {
  description = <<-EOT
    1.14.1: the current LTS release. Kubernetes 1.36 needs Karpenter 1.13 or
    newer -- Karpenter refuses to start against a Kubernetes version outside
    its compatibility matrix, so check that matrix before upgrading either.
  EOT
  type        = string
  default     = "1.14.1"
}

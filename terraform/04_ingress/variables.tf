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

variable "domain" {
  description = "Zone in Cloudflare. The certificate covers *.<domain>."
  type        = string
  default     = "nopega.net"
}

variable "cloudflare_zone_id" {
  description = <<-EOT
    Zone ID of the domain in Cloudflare: dashboard -> nopega.net -> Overview,
    right-hand column, "Zone ID". Not secret. Put it in terraform.tfvars
    (gitignored) or pass -var.
  EOT
  type        = string
}

variable "lbc_chart_version" {
  description = <<-EOT
    aws-load-balancer-controller Helm chart. 1.14.0 (controller v2.14.0) is
    what the original platform ran, and iam-policy.json in this folder is the
    policy published for that version. Upgrading the chart means replacing
    that file with the policy for the new version too.
  EOT
  type        = string
  default     = "1.14.0"
}

variable "external_dns_chart_version" {
  description = <<-EOT
    external-dns Helm chart. null = latest at the time of apply. After the
    first apply, pin it to what got installed (`helm list -n external-dns`)
    so a later apply cannot upgrade it by surprise.
  EOT
  type        = string
  default     = null
}

variable "cloudflare_token_secret" {
  description = <<-EOT
    Kubernetes Secret (namespace external-dns, key api-token) holding the
    Cloudflare token for external-dns. Created by hand with kubectl BEFORE
    apply -- see README -- so the token never enters Terraform state.
  EOT
  type        = string
  default     = "cloudflare-api-token"
}

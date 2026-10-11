variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "cluster_name" {
  type    = string
  default = "vpn-data-platform"
}

variable "hostname" {
  description = "Argo CD UI. Covered by the *.nopega.net certificate from stage 04."
  type        = string
  default     = "argocd.nopega.net"
}

variable "chart_version" {
  description = "argo-cd Helm chart 10.3.0 = Argo CD v3.5.0, the version the original platform ran."
  type        = string
  default     = "10.3.0"
}

variable "apps_repo_url" {
  description = "Git repository root watches (its apps/ folder). Public, so Argo CD needs no credentials."
  type        = string
  default     = "https://github.com/nopega/vpn-data-platform-apps.git"
}

variable "apps_repo_revision" {
  type    = string
  default = "main"
}

variable "vpc_cidr" {
  description = "Only this range may reach the ALB: in practice, the Tailscale router."
  type        = string
  default     = "10.42.0.0/16"
}

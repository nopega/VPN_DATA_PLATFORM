variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "vpn-data-platform"
}

variable "instance_type" {
  description = <<-EOT
    t4g.nano: 2 vCPU (burstable), 0.5 GiB, ARM. Enough to route a handful of
    users and forward node egress. Its network baseline is low, so a large
    image pull will be slow; move to t4g.micro or t4g.small if that hurts.
    0.5 GiB is too little for dnf to install packages, which is why the boot
    script adds 1 GiB of swap first -- t4g.micro (1 GiB, ~$7.40/mo) would not
    need it.
  EOT
  type        = string
  default     = "t4g.nano"
}

variable "tailscale_auth_key_secret_name" {
  description = <<-EOT
    Name of the Secrets Manager secret holding the Tailscale auth key.

    Created by hand BEFORE apply (see README), never by Terraform. Terraform
    only looks up the secret's ARN to grant the instance permission to read
    it; the key itself never passes through Terraform, so it never lands in
    terraform.tfstate.
  EOT
  type        = string
  default     = "vpn-data-platform/tailscale-auth-key"
}

variable "tailscale_hostname" {
  description = "Name this machine shows up as in the Tailscale admin console."
  type        = string
  default     = "vpn-data-platform-router"
}

variable "act_as_nat" {
  description = <<-EOT
    Also act as the NAT for the private subnets: point their 0.0.0.0/0 route
    at this instance. Replaces the ~$47/month NAT gateway with this ~$4/month
    instance. Must stay false if stage 01 was applied with
    enable_nat_gateway = true, because both would own the same route.
  EOT
  type        = bool
  default     = true
}

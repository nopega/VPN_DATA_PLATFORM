variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project_name" {
  type    = string
  default = "vpn-data-platform"
}

variable "cluster_name" {
  description = "Must match cluster_name in stage 01 -- the subnet tags carry it."
  type        = string
  default     = "vpn-data-platform"
}

variable "kubernetes_version" {
  description = <<-EOT
    1.36: released on EKS June 2026, standard support until August 2027.

    Not 1.34 like the original platform -- its standard support ends
    2 December 2026, after which EKS bills the control plane at the extended
    support rate, six times the standard one. Not 1.37 either: it is two weeks
    old, and Helm charts for the platform components tend to lag a new
    release.
  EOT
  type        = string
  default     = "1.36"
}

# ---------------------------------------------------------------------------
# On-demand group: system pods now, platform components later
# ---------------------------------------------------------------------------

variable "ondemand_instance_type" {
  description = <<-EOT
    t3.medium (2 vCPU, 4 GiB, ~$39/mo in Singapore) is enough to bring the
    cluster up with its system pods. The platform components need more: the
    original ran 5 x m5.large. Raise this, or the node count, as components
    are added -- not before.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "ondemand_min" {
  type    = number
  default = 1
}

variable "ondemand_desired" {
  type    = number
  default = 1
}

variable "ondemand_max" {
  type    = number
  default = 3
}

# ---------------------------------------------------------------------------
# Spot group: Spark executors only, zero nodes until a job asks for them
# ---------------------------------------------------------------------------

variable "spot_instance_types" {
  description = "Several types so Spot has more capacity pools to draw from."
  type        = list(string)
  default     = ["m5.large", "m5a.large", "m6i.large", "m6a.large"]
}

variable "spot_max" {
  type    = number
  default = 4
}

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
    t3.xlarge: 4 vCPU, 16 GiB (~14 GiB allocatable), ~$155/mo in Singapore.

    Was t3.medium (2 vCPU, 4 GiB) to bring the cluster up. That stopped being
    enough at the first data component: with the original platform's
    settings a Trino worker requests 4 GiB and the coordinator 2 GiB, while
    a t3.medium has ~3.3 GiB allocatable in total -- the worker could never
    be scheduled anywhere. 16 GiB fits Polaris + full-size Trino +
    monitoring; Airflow and Spark drivers will need a second node.

    Changing this replaces the node group (create_before_destroy): new node
    up first, then the old one is drained.
  EOT
  type        = string
  default     = "t3.xlarge"
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

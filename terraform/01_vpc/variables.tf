variable "region" {
  description = "AWS region. Singapore, the same as the original platform."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Prefix for every resource name and the value of the Project tag."
  type        = string
  default     = "vpn-data-platform"
}

variable "cluster_name" {
  description = <<-EOT
    Name the EKS cluster will have in a later stage. Written into subnet tags
    now so the AWS Load Balancer Controller can find these subnets without
    any extra configuration.
  EOT
  type        = string
  default     = "vpn-data-platform"
}

variable "vpc_cidr" {
  description = <<-EOT
    Address range of the whole VPC.

    Chosen on purpose rather than left to a default. Once Tailscale routes this
    range to every user's laptop, it must not overlap any network those
    laptops sit on. 192.168.0.0/16 (what eksctl picked for the original
    platform) collides with almost every home router, and 10.0.0.0/16 with
    many offices. 10.42.0.0/16 is unusual enough to be safe.
  EOT
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) == 16
    error_message = "vpc_cidr must be a valid /16 -- the subnet maths in main.tf assumes it."
  }
}

variable "az_count" {
  description = <<-EOT
    How many availability zones to spread subnets across. EKS and the
    Application Load Balancer need at least two.

    Two, matching the architecture diagram. A third zone adds little real
    availability while the NAT gateway and RDS each live in one zone anyway,
    and it costs in two quiet ways: $0.01/GB each direction for traffic that
    crosses zones (Trino workers exchanging data), and EBS volumes pinned to a
    zone with fewer nodes in it. The one thing it would buy is more Spot
    capacity pools for Spark executors.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Create one NAT gateway so private subnets can reach the internet.

    OFF by default because it is the only resource in this stage that costs
    money: in ap-southeast-1, $0.059 an hour (about $43 a month) plus $0.045
    per GB, plus about $3.60 a month for its public IPv4 address. (The
    original platform's docs quote $32, which is the us-east-1 hourly rate.) Nothing in this stage needs it. The cluster
    stage will (nodes pull public images, Tailscale has to reach its
    coordination servers), and that is the moment to decide.
  EOT
  type        = bool
  default     = false
}

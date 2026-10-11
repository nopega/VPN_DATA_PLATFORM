# Stage 03 -- the EKS cluster, reachable only through Tailscale.
#
#   kubectl (Mac) ══Tailscale══▶ router ──▶ API server endpoint (10.42.x.x)
#   node (private subnet) ─────────────────▶ API server endpoint (10.42.x.x)
#   node ──▶ router (NAT) ──▶ internet       (image pulls, AWS APIs)
#
# The API server has NO public endpoint. Its DNS name then resolves ONLY
# through the VPC's own resolver (10.42.0.2) -- public DNS answers "no such
# host". Laptops get it via Tailscale split DNS: queries for
# ap-southeast-1.eks.amazonaws.com go to 10.42.0.2 over the tunnel (set once
# in the Tailscale admin console, see README).
#
# Recovery if the router dies: re-apply stage 02. That uses the AWS API, not
# the Kubernetes API, so losing the way in never locks you out of fixing it.

data "terraform_remote_state" "vpc" {
  backend = "local"
  config = {
    path = "${path.module}/../01_vpc/terraform.tfstate"
  }
}

locals {
  vpc_id             = data.terraform_remote_state.vpc.outputs.vpc_id
  vpc_cidr           = data.terraform_remote_state.vpc.outputs.vpc_cidr
  private_subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids
}

# ===========================================================================
# Control plane
# ===========================================================================

resource "aws_iam_role" "cluster" {
  name = "${var.project_name}-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# The security group EKS creates for the cluster only admits traffic from
# itself (control plane <-> nodes). The Tailscale router is not a member, so
# without this extra group kubectl from the Mac would time out at the API
# server even with the route approved. The router rewrites the source of
# Tailscale traffic to its own VPC address, so "from the VPC" covers it.
resource "aws_security_group" "api_access" {
  name        = "${var.project_name}-api-access"
  description = "Kubernetes API from inside the VPC, including the Tailscale router"
  vpc_id      = local.vpc_id
  tags        = { Name = "${var.project_name}-api-access" }
}

resource "aws_vpc_security_group_ingress_rule" "api_from_vpc" {
  security_group_id = aws_security_group.api_access.id
  description       = "Kubernetes API (443) from the VPC / Tailscale router"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = local.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [aws_security_group.api_access.id]
  }

  access_config {
    # Access entries (an AWS API) instead of the aws-auth ConfigMap.
    authentication_mode = "API"
    # Whoever runs `terraform apply` becomes cluster admin, so kubectl works
    # straight away with the same AWS credentials.
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Install vpc-cni, kube-proxy and coredns as MANAGED add-ons below instead
  # of the unmanaged copies EKS would otherwise drop in. Managed ones can be
  # upgraded with Terraform; unmanaged ones silently drift.
  bootstrap_self_managed_addons = false

  # When this version's standard support ends, upgrade instead of quietly
  # moving to extended support at six times the hourly price.
  upgrade_policy {
    support_type = "STANDARD"
  }

  # Control-plane logging stays off, as in the original platform: CloudWatch
  # ingestion is billed per GB and nothing reads these logs yet.

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ===========================================================================
# Add-ons that must exist BEFORE nodes start
# ===========================================================================
# vpc-cni gives pods their VPC addresses; a node without it never becomes
# Ready. kube-proxy and the pod identity agent are DaemonSets that should be
# waiting for the first node, not installed after it.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
}

# EKS Pod Identity: lets a Kubernetes service account assume an IAM role.
# Simpler successor to the IRSA + OIDC provider setup the original used.
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
}

# ===========================================================================
# Nodes
# ===========================================================================

resource "aws_iam_role" "node" {
  name = "${var.project_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Shell on a node through Session Manager when debugging; no SSH key.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "ondemand" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "ng-ondemand"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = local.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "ON_DEMAND"
  instance_types = [var.ondemand_instance_type]
  disk_size      = 30

  scaling_config {
    min_size     = var.ondemand_min
    desired_size = var.ondemand_desired
    max_size     = var.ondemand_max
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "critical"
  }

  lifecycle {
    # Scaling up and down (scale scripts, a future autoscaler) changes the
    # desired size outside Terraform; don't fight it on every plan.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}

resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "ng-spot"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = local.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  capacity_type  = "SPOT"
  instance_types = var.spot_instance_types
  disk_size      = 50

  # Zero nodes, zero cost, until something schedules onto it.
  scaling_config {
    min_size     = 0
    desired_size = 0
    max_size     = var.spot_max
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    workload  = "batch"
    lifecycle = "spot"
  }

  # Only pods that tolerate this (Spark executors) land here. Anything else
  # -- a Spark driver, Trino, Polaris -- would lose work on a Spot reclaim.
  taint {
    key    = "spot"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}

# ===========================================================================
# Add-ons that need a node to run on
# ===========================================================================

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [aws_eks_node_group.ondemand]
}

# The EBS CSI driver turns PersistentVolumeClaims into EBS volumes
# (Prometheus, Harbor, anything with a disk). It calls the EC2 API, so it
# gets its own role through Pod Identity -- not the node's role, which every
# pod on the node could otherwise borrow.
resource "aws_iam_role" "ebs_csi" {
  name = "${var.project_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [
    aws_eks_node_group.ondemand,
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

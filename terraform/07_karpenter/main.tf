# Stage 07 -- Karpenter: nodes appear when pods need them and go away when
# they do not.
#
#   pod Pending (no room) ──▶ Karpenter picks an instance type that fits ──▶ EC2 launched
#   node empty / underused ──▶ Karpenter moves pods, terminates the node
#   Spot reclaim notice  ──▶ EventBridge ──▶ SQS ──▶ Karpenter drains the node first
#
# This stage holds the AWS side and the controller. WHICH machines it may
# create (NodePools, EC2NodeClass) is cluster configuration and lives in the
# apps repository, applied by Argo CD.
#
# The existing managed node group stays: it hosts Karpenter itself (Karpenter
# must not run on nodes it manages) and the always-on platform pods.

locals {
  private_subnet_ids        = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  cluster_security_group_id = data.terraform_remote_state.eks.outputs.cluster_security_group_id
  node_role_arn             = data.terraform_remote_state.eks.outputs.node_role_arn
  discovery_tag             = { key = "karpenter.sh/discovery", value = var.cluster_name }
}

# ---------------------------------------------------------------------------
# AWS side: controller IAM role (Pod Identity), interruption queue + rules
# ---------------------------------------------------------------------------

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = var.cluster_name

  # Controller identity through Pod Identity: kube-system/karpenter.
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"
  iam_role_name                   = "${var.project_name}-karpenter"
  iam_role_use_name_prefix        = false

  # The controller policy is ~7 KB of JSON -- over the 6,144-character limit
  # for a managed IAM policy (first apply failed with "LimitExceeded: Cannot
  # exceed quota for PolicySize: 6144"). Inline role policies allow 10,240.
  enable_inline_policy = true

  # Karpenter's nodes use the SAME role as the managed node group (stage 03).
  # That role already has its EKS access entry, so nodes Karpenter launches
  # can join without a second role or a second entry.
  create_node_iam_role = false
  node_iam_role_arn    = local.node_role_arn
  create_access_entry  = false

  # SQS queue + EventBridge rules for Spot interruption, rebalance, and
  # instance state changes.
  enable_spot_termination = true
  queue_name              = "${var.project_name}-karpenter"
}

# Karpenter finds subnets and security groups by tag (EC2NodeClass selectors
# in the apps repo). Tagged here rather than in stages 01/03 so those stages
# stay unaware of Karpenter.
resource "aws_ec2_tag" "subnet_discovery" {
  for_each    = toset(local.private_subnet_ids)
  resource_id = each.value
  key         = local.discovery_tag.key
  value       = local.discovery_tag.value
}

resource "aws_ec2_tag" "security_group_discovery" {
  resource_id = local.cluster_security_group_id
  key         = local.discovery_tag.key
  value       = local.discovery_tag.value
}

# ---------------------------------------------------------------------------
# The controller
# ---------------------------------------------------------------------------

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  values = [yamlencode({
    settings = {
      clusterName       = var.cluster_name
      interruptionQueue = module.karpenter.queue_name
    }

    serviceAccount = { name = "karpenter" }

    # One replica, small requests. The chart defaults to 2 x (1 CPU, 1 GiB),
    # half of the 4-vCPU on-demand node. Fine to raise once the cluster
    # carries real load; a restart only pauses provisioning for seconds.
    replicas = 1
    controller = {
      resources = {
        requests = { cpu = "250m", memory = "512Mi" }
        limits   = { memory = "1Gi" }
      }
    }

    # On the managed node group. (The chart also keeps Karpenter off nodes
    # Karpenter launched -- it would otherwise be able to remove its own node.)
    nodeSelector = { workload = "critical" }
  })]

  depends_on = [
    module.karpenter,
    aws_ec2_tag.subnet_discovery,
    aws_ec2_tag.security_group_discovery,
  ]
}

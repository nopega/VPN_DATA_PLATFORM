# Stage 04 -- the way in for services, end to end:
#
#   laptop ══Tailscale══▶ router ──▶ internal ALB (10.42.x.x, TLS *.nopega.net) ──▶ pod
#      ▲
#      └─ test.nopega.net ─CNAME─▶ internal-k8s-...elb.amazonaws.com ─▶ 10.42.x.x
#         (record written by external-dns)        (AWS publishes private IPs for
#                                                   internal load balancers)
#
# Three pieces:
#   1. ONE wildcard certificate for *.nopega.net. The original platform asked
#      ACM for a fixed list of names and had to re-request the certificate
#      three times as names were added. A wildcard ends that for good.
#   2. AWS Load Balancer Controller: turns Ingress objects into ALBs.
#   3. external-dns: writes each Ingress hostname into Cloudflare, pointing at
#      whichever ALB exists now -- so a rebuilt ALB with a new name no longer
#      leaves DNS pointing at the old one.

data "terraform_remote_state" "vpc" {
  backend = "local"
  config = {
    path = "${path.module}/../01_vpc/terraform.tfstate"
  }
}

locals {
  vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id
}

# ===========================================================================
# 1. Certificate: *.nopega.net, validated through Cloudflare
# ===========================================================================

resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM proves we own the domain by asking for a CNAME with a value it chose.
# Terraform writes that CNAME into Cloudflare itself -- the step the original
# platform did by hand-importing a zone file, which failed silently three
# times. The record must stay: ACM re-reads it to renew automatically.
resource "cloudflare_dns_record" "acm_validation" {
  for_each = {
    for o in aws_acm_certificate.wildcard.domain_validation_options : o.domain_name => o
  }

  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(each.value.resource_record_name, ".")
  type    = each.value.resource_record_type
  content = trimsuffix(each.value.resource_record_value, ".")
  ttl     = 1
  proxied = false
  comment = "ACM validation for *.${var.domain} (${var.project_name}). Do not delete: renewals need it."
}

# Waits (up to ~45 min, usually 2-5) until ACM sees the record and issues.
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in cloudflare_dns_record.acm_validation : r.name]
}

# ===========================================================================
# 2. AWS Load Balancer Controller
# ===========================================================================

resource "aws_iam_policy" "lbc" {
  name   = "${var.project_name}-aws-load-balancer-controller"
  policy = file("${path.module}/iam-policy.json")
}

resource "aws_iam_role" "lbc" {
  name = "${var.project_name}-aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

# Pod Identity: the controller's service account gets this role. Must exist
# before the pods start -- the agent injects credentials at pod creation.
resource "aws_eks_pod_identity_association" "lbc" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lbc.arn
}

resource "helm_release" "lbc" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version

  values = [yamlencode({
    clusterName = var.cluster_name
    # Given explicitly so the controller never has to ask the instance
    # metadata service, which pods on EKS nodes may not be able to reach.
    region = var.region
    vpcId  = local.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.lbc,
    aws_iam_role_policy_attachment.lbc,
  ]
}

# ===========================================================================
# 3. external-dns
# ===========================================================================

resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.external_dns_chart_version

  # The namespace and its Secret are created by hand first (README), so the
  # Cloudflare token is never in Terraform's state.
  create_namespace = false

  values = [yamlencode({
    provider = { name = "cloudflare" }
    env = [{
      name = "CF_API_TOKEN"
      valueFrom = {
        secretKeyRef = { name = var.cloudflare_token_secret, key = "api-token" }
      }
    }]

    sources       = ["ingress", "service"]
    domainFilters = [var.domain]

    # upsert-only: create and update, NEVER delete. The zone also holds
    # records nothing here manages (ssh.nopega.net, the old platform's
    # leftovers); a mistake in sync mode could remove them.
    policy = "upsert-only"

    # Ownership marker. external-dns only ever changes records it wrote,
    # recognised by TXT records carrying this id. A name that already exists
    # without one -- e.g. trino.nopega.net from the old platform -- is left
    # alone until deleted by hand.
    txtOwnerId = var.project_name

    interval = "1m"
  })]

  depends_on = [helm_release.lbc]
}

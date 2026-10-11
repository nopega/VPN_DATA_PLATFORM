# Stage 05 -- Argo CD, reachable at https://argocd.nopega.net over Tailscale.
#
# Terraform installs Argo CD itself and nothing else. Everything after this
# -- Polaris, Trino, Airflow, Harbor, monitoring -- is an Argo CD Application
# in git, reconciled by Argo CD, the same app-of-apps shape as the original
# platform.
#
# Settings are carried over from the original's values.yaml, where every
# change was marked "data-platform":
#   - dex off (no SSO provider yet), notifications off (no webhook targets)
#   - on-demand nodes only (workload=critical), never Spot
#   - the same resource requests and limits per component
# Two things differ:
#   - the UI is served through the shared INTERNAL ALB instead of being
#     reachable only by `kubectl port-forward`
#   - as a consequence, argocd-server runs plain HTTP behind the ALB, which
#     terminates TLS with the wildcard certificate

locals {
  # Same annotations as the smoke test: one internal ALB shared by every
  # Ingress in the group, TLS only, reachable only from inside the VPC.
  alb_annotations = {
    "alb.ingress.kubernetes.io/scheme"           = "internal"
    "alb.ingress.kubernetes.io/target-type"      = "ip"
    "alb.ingress.kubernetes.io/group.name"       = "vpn-data-platform-internal"
    "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTPS\":443}]"
    "alb.ingress.kubernetes.io/ssl-policy"       = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    "alb.ingress.kubernetes.io/inbound-cidrs"    = var.vpc_cidr
    # argocd-server speaks plain HTTP (server.insecure below); without this
    # the ALB would speak HTTPS to it and every target would be unhealthy.
    "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
    # Answers 200 without a session. "/" redirects to the login page, which
    # an ALB health check reads as failure.
    "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
  }

  resources = {
    controller     = { requests = { cpu = "100m", memory = "256Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
    server         = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "250m", memory = "256Mi" } }
    repoServer     = { requests = { cpu = "50m", memory = "128Mi" }, limits = { cpu = "300m", memory = "512Mi" } }
    applicationSet = { requests = { cpu = "25m", memory = "64Mi" }, limits = { cpu = "100m", memory = "128Mi" } }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.chart_version

  # The first install pulls several images through the router; give it time.
  timeout = 600

  values = [yamlencode({
    global = {
      # Argo CD builds its own absolute links (UI, login redirect) from this.
      domain       = var.hostname
      nodeSelector = { workload = "critical" }
    }

    configs = {
      params = {
        # TLS ends at the ALB. Inside the cluster the server answers HTTP.
        "server.insecure" = true
      }
    }

    controller     = { resources = local.resources.controller }
    repoServer     = { resources = local.resources.repoServer }
    applicationSet = { resources = local.resources.applicationSet }

    server = {
      resources = local.resources.server
      ingress = {
        enabled          = true
        ingressClassName = "alb"
        annotations      = local.alb_annotations
        # Produces spec.tls.hosts = [hostname]. The load balancer controller
        # reads that to find the *.nopega.net certificate in ACM; the secret
        # name the chart also writes there is ignored.
        tls = true
      }
    }

    dex           = { enabled = false }
    notifications = { enabled = false }
  })]
}

# Stage 11 -- GitHub Actions runners inside the cluster (Actions Runner
# Controller, "ARC").
#
# WHY INSIDE THE CLUSTER
# ----------------------
# Harbor is reachable only from inside the VPC (internal ALB, 10.42.0.0/16).
# A GitHub-hosted runner is on the internet and cannot see it. A runner pod
# here is already in the VPC, reaches harbor.nopega.net directly, and builds
# on a real x86 node -- no emulation, unlike building on the Mac.
#
#   git push --tags ──▶ GitHub ──(job queued)──▶ listener pod (arc-systems)
#                                                  │ asks for a runner
#                                                  ▼
#                        runner pod (arc-runners) on a Karpenter Spot node
#                          docker build ──▶ docker push harbor.nopega.net
#                        job done ──▶ pod deleted ──▶ node removed (1 min)
#
# minRunners = 0: no job, no runner pod, no node, no cost. The first job
# waits ~1-2 minutes for Karpenter to start a node.
#
# The GitHub token the listener needs is a Secret made by bootstrap/ci.sh,
# not here -- Terraform would keep it in terraform.tfstate.
#
# SECURITY: these runners run whatever a workflow in the repository says,
# inside the VPC, in a privileged container (Docker-in-Docker needs it). So
# only people who can push to the repository may trigger them -- the workflow
# has no pull_request trigger, which is what would let a fork run code here.

resource "helm_release" "arc_controller" {
  name             = "arc"
  namespace        = "arc-systems"
  create_namespace = true
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set-controller"
  version          = var.arc_version

  values = [yamlencode({
    replicaCount = 1
    nodeSelector = { workload = "critical" }
    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })]
}

resource "helm_release" "runner_scale_set" {
  name             = var.runner_scale_set_name
  namespace        = "arc-runners"
  create_namespace = false # made by bootstrap/ci.sh together with the token Secret
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = var.arc_version

  values = [yamlencode({
    githubConfigUrl    = var.github_config_url
    githubConfigSecret = "github-runner-auth"
    runnerScaleSetName = var.runner_scale_set_name

    minRunners = 0
    maxRunners = var.max_runners

    # Docker daemon in a sidecar, so `docker build` / `docker push` work as
    # on any machine. The cost is a privileged container -- see SECURITY.
    containerMode = { type = "dind" }

    # The listener: one small pod that waits for jobs. On-demand nodes.
    listenerTemplate = {
      spec = {
        nodeSelector = { workload = "critical" }
        containers   = [{ name = "listener" }]
      }
    }

    controllerServiceAccount = {
      namespace = "arc-systems"
      name      = "arc-gha-rs-controller"
    }

    # The runner: on Karpenter's Spot pool, like Spark executors. An
    # interrupted build is simply re-run.
    template = {
      spec = {
        nodeSelector = { workload = "batch" }
        tolerations = [{
          key      = "spot"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }]
        containers = [{
          name    = "runner"
          image   = "ghcr.io/actions/actions-runner:latest"
          command = ["/home/runner/run.sh"]
          resources = {
            requests = { cpu = "2", memory = "4Gi" }
            limits   = { memory = "8Gi" }
          }
        }]
      }
    }
  })]

  depends_on = [helm_release.arc_controller]
}

# The `root` Application, created by the same Helm release that installs
# Argo CD (via the chart's extraObjects). A fresh cluster is therefore wired
# to its app repository with no manual `kubectl apply`: Argo CD starts, reads
# apps/ in the app repo, and installs everything in sync-wave order.

locals {
  root_application = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "root"
      namespace = "argocd"
      # Deleting root also deletes every Application it created, and through
      # their own finalizers everything they deployed. To re-point root
      # without that cascade, remove this finalizer first (see README).
      finalizers = ["resources-finalizer.argocd.argoproj.io"]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.apps_repo_url
        targetRevision = var.apps_repo_revision
        path           = "apps"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = { prune = true, selfHeal = true }
      }
    }
  }

  # Argo CD stopped computing health for Application objects in v1.8, so by
  # default a sync wave of Applications only orders their CREATION -- wave 10
  # starts while wave -20 is still coming up. This restores the check, so
  # root waits for each child Application to report Healthy before moving on
  # to the next wave. (The original platform's README claimed this behaviour
  # without this setting.)
  application_health_lua = <<-LUA
    hs = {}
    hs.status = "Progressing"
    hs.message = ""
    if obj.status ~= nil and obj.status.health ~= nil then
      hs.status = obj.status.health.status
      if obj.status.health.message ~= nil then
        hs.message = obj.status.health.message
      end
    end
    return hs
  LUA
}

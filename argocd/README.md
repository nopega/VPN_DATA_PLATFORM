# argocd/

What runs in the cluster, as Argo CD reads it from git.

```
argocd/
├── root.yaml          applied once by hand; watches apps/
├── apps/              one Application per component
│   └── smoke-test.yaml
└── workloads/         plain manifests for components that are not Helm charts
    └── smoke-test/
```

## How a change reaches the cluster

```
edit a file → git commit → git push
   → Argo CD polls GitHub (every ~3 min) → sees the new commit
   → applies the difference → the cluster matches git
```

Nothing is `kubectl apply`-ed by hand except `root.yaml`, once. To speed up a
check after a push, press **Refresh** on the application in the UI.

## Adding a component

1. Add `apps/<name>.yaml` — an Application pointing either at a Helm chart
   (repo URL, chart, version, values) or at `workloads/<name>/`.
2. Push. `root` creates the Application; the Application deploys the component.

Before adding anything: the single t3.medium node is at its 17-pod limit.
See BACKLOG.md.

## Bootstrapping

```bash
kubectl apply -f argocd/root.yaml
```

Run once, after `terraform/05_argocd`. From then on the cluster follows git.

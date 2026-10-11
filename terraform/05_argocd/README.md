# 05_argocd

Argo CD at **https://argocd.nopega.net**, reachable only over Tailscale.
From here on, platform components are Argo CD Applications in git rather than
Terraform resources: Terraform for what touches AWS and Cloudflare, Argo CD
for what runs in the cluster.

Chart 10.3.0 (Argo CD v3.5.0) with the original platform's settings:
dex and notifications off, on-demand nodes only, the same resource requests.
The one change is access: through the shared internal ALB instead of
`kubectl port-forward`.

## Before `apply` — three checks

### 1. Delete the old `argocd` record in Cloudflare

`argocd.nopega.net` still points at the old platform's deleted ALB. It has no
ownership marker from external-dns, so external-dns will **not** overwrite it
— the hostname would keep resolving to nothing. Cloudflare → DNS → Records →
`argocd` → Delete. (Leave the other old ones until their service moves here.)

### 2. Room on the node

One t3.medium holds at most **17 pods** (a limit from how many network
addresses the instance type can hold, not from CPU or memory). Argo CD adds 5.

```bash
kubectl get pods -A --field-selector=status.phase=Running --no-headers | wc -l
```

Must be **12 or fewer**. The smoke test from stage 04 takes one — delete it
first if it is still running (`kubectl delete -f ../04_ingress/smoke-test.yaml`).
The next components will not fit at all; see BACKLOG.md, "pod limit".

### 3. Tailscale connected

Helm talks to the private Kubernetes API.

## Apply

```bash
terraform init
terraform plan     # expect: 1 to add
terraform apply    # ~2-4 min
```

## Log in

```bash
kubectl -n argocd get pods                     # all Running
kubectl -n argocd get ingress                  # ADDRESS = internal-k8s-vpndataplatformin-…  (the SAME ALB as the smoke test, if it still exists)
dig @1.1.1.1 +short argocd.nopega.net          # check here first — see the note below
$(terraform output -raw initial_admin_password)
```

Open https://argocd.nopega.net, user `admin`, the printed password. Then
**User Info → Update Password**, and delete the bootstrap secret:

```bash
kubectl -n argocd delete secret argocd-initial-admin-secret
```

**DNS note.** Ask `1.1.1.1` before opening the browser. If the Mac asks for a
name before external-dns has created it, the "does not exist" answer is
cached for up to 30 minutes (Cloudflare's negative TTL, 1800 s) — which is
exactly what happened with `test.nopega.net`.

## What comes next

Argo CD is empty until it has a git repository to watch. That needs this
folder pushed to GitHub, and an Application (`root`) pointing at a folder of
other Applications — the app-of-apps shape the original used.

## Tear down

```bash
terraform destroy
```

Removes the Ingress with the release; the controller then removes the ALB
listener rule (and the ALB itself if nothing else is in the group).

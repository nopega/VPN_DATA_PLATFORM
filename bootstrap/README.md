# bootstrap/

One-time steps that must happen before a component can start, and that do
not fit Terraform (they talk to a database or to the running cluster) or
Argo CD (they create secrets, which never go into git).

Each script is safe to re-run and keeps its secrets in AWS Secrets Manager
first, Kubernetes second — so a rebuilt cluster can be re-seeded from the
same values.

| Script | Run after | Before pushing |
|---|---|---|
| `polaris.sh` | `terraform/06_data_foundation` | `git mv argocd/next/polaris.yaml argocd/apps/` |

All need Tailscale connected (kubectl, and psql to RDS, go through it).

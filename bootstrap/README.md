# bootstrap/

One-time steps that must happen before a component can start, and that do
not fit Terraform (they talk to a database or to the running cluster) or
Argo CD (they create secrets, which never go into git).

Each script is safe to re-run and keeps its secrets in AWS Secrets Manager
first, Kubernetes second — so a rebuilt cluster can be re-seeded from the
same values.

| Script | Run after | Before pushing |
|---|---|---|
| `polaris.sh` | `terraform/06_data_foundation` | moving `next/polaris.yaml` to `apps/` in vpn-data-platform-apps |
| `polaris_catalog.sh` | Polaris pod `Running` | Trino (needs the catalog to exist) |
| `trino.sh` | `polaris_catalog.sh` | moving `next/trino.yaml` to `apps/` in vpn-data-platform-apps (and deleting the old `trino` record in Cloudflare) |
| `monitoring.sh` | stage 07 (any time the cluster is up) | moving `next/monitoring.yaml` to `apps/` in vpn-data-platform-apps (and deleting the old `grafana` and `prometheus` records in Cloudflare) |
| `harbor.sh` | `terraform/08_registry` | moving `next/harbor.yaml` to `apps/` in vpn-data-platform-apps (and deleting the old `harbor` record in Cloudflare) |
| `spark.sh` | `terraform/09_spark`, Harbor project `ice-berg-platform` exists | building the image and moving `next/spark-operator.yaml` to `apps/` in vpn-data-platform-apps |
| `airflow.sh` (then `airflow.sh admin`) | `terraform/10_airflow` | moving `next/airflow.yaml` to `apps/` (and deleting the old `airflow` record in Cloudflare); `admin` once the api-server pod is Running |
| `ci.sh` | platform scaled up; Harbor project `ice-berg-platform` exists | `terraform/11_ci` (the runner listener needs the GitHub token Secret) |

All need Tailscale connected (kubectl, and psql to RDS, go through it).

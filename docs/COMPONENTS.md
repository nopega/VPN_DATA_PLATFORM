# Components

Every component of the platform, the version that runs, what it does here and
why it was chosen over the alternatives. Versions are the ones pinned in this
repository and in `vpn-data-platform-apps` — nothing floats on `latest`, so a
rebuild months from now produces the same platform.

Where a component is delivered by a Helm chart, both the chart version and the
application version are listed, because they move independently. The rule
throughout: **the chart's `appVersion` decides the application version.** It is
the combination the chart's maintainers tested; overriding it means running a
pairing nobody tested.

## 1. Infrastructure (this repository, Terraform)

| Component | Version | Role | Stage |
|---|---|---|---|
| **VPC** | — | `10.42.0.0/16`, private subnets for every workload, S3 gateway endpoint | `01_vpc` |
| **Tailscale subnet router** | `t4g.nano`, Amazon Linux | the only way into the VPC; also the NAT for private subnets | `02_tailscale_router` |
| **Amazon EKS** | **1.36**, private API endpoint | Kubernetes control plane; one managed node group `t3.xlarge` (1–3) for system pods; Pod Identity for workload AWS access | `03_eks` |
| **AWS Load Balancer Controller** | chart 1.14.0 (controller v2.14.0) | turns every Ingress into rules on **one** internal ALB | `04_ingress` |
| **ACM + external-dns** | wildcard certificate, Cloudflare provider | TLS for every hostname; DNS records written from Ingress hosts | `04_ingress` |
| **Argo CD** | chart 10.3.0 | GitOps: an app-of-apps reconciles everything in `vpn-data-platform-apps` | `05_argocd` |
| **S3 + RDS** | RDS PostgreSQL **17**, `db.t4g.micro` | warehouse and logs buckets; one database instance for Polaris, Harbor and Airflow | `06_data_foundation` |
| **Karpenter** | 1.14.1 | node autoscaling: NodePool `general` (On-Demand) and `spot-batch` (Spot, for Spark and CI) | `07_karpenter` |
| **Registry storage** | — | S3 bucket and scoped IAM user for Harbor | `08_registry` |
| **Spark IAM** | — | Pod Identity role for Spark (event logs only) | `09_spark` |
| **Airflow IAM** | — | Pod Identity role for five Airflow ServiceAccounts (task logs only) | `10_airflow` |
| **Actions Runner Controller** | 0.15.0 | self-hosted GitHub Actions runners inside the cluster, 0–2 Docker-in-Docker runners on Spot | `11_ci` |
| **AWS Secrets Manager** | managed | authoritative copy of every credential, written by `bootstrap/*.sh` | `bootstrap/` |

## 2. Data platform (apps repository, Argo CD)

| Component | Version | Role |
|---|---|---|
| **Apache Iceberg** | 1.11.0 | table format: ACID commits, schema and partition evolution, time travel, hidden partitioning |
| **Apache Polaris** | 1.5.0 (chart 1.5.0) | Iceberg REST catalog: which `metadata.json` is current for each table, atomic commits, role-based grants, **credential vending** |
| **Apache Spark** | 4.0.1 (Scala 2.13, Java 21) | ETL: ingest, clean, aggregate, written to Iceberg. Image built by CI into Harbor |
| **Kubeflow Spark Operator** | 2.5.0 (chart 2.5.0) | owns the `SparkApplication` resource and turns it into driver and executor pods |
| **Trino** | 480 (chart 1.42.2) | SQL query engine over Iceberg, password authentication, access rules, resource groups |
| **Apache Airflow** | 3.2.2 (chart 1.22.0), KubernetesExecutor | orchestration; DAGs synced from the apps repository with git-sync, task logs to S3 |
| **Harbor** | 2.15.1 (chart 1.19.1) | private image registry on S3, robot accounts for pull (Spark) and push (CI) |
| **kube-prometheus-stack** | chart 88.3.0 — Prometheus 3.13.2, Grafana 13.1.3, Alertmanager | metrics, dashboards, alert rules. Prometheus keeps **7 days or 18 GiB** on a 20 Gi gp3 volume, whichever is reached first |
| **EBS CSI + gp3 StorageClass** | — | block storage for Prometheus, Grafana and other PersistentVolumeClaims |

### How a pipeline run flows through them

```
Airflow DAG
  → SparkKubernetesOperator creates a SparkApplication
  → Spark Operator starts driver + executors (Karpenter adds a Spot node if needed)
  → image pulled from Harbor (robot account spark-pull)
  → Spark authenticates to Polaris as principal "etl"
  → Polaris vends short-lived S3 credentials for that table
  → Parquet + metadata written to the warehouse bucket
  → Trino reads the same table through Polaris → BI tool
```

The diagram of the same flow is page 3 of
[`diagrams/vpn_data_platform.drawio`](diagrams/vpn_data_platform.drawio).

## 3. Version compatibility

The versions are not "the newest of everything". Four pairings constrain the
rest.

**Iceberg ↔ Spark — the binding constraint.** Iceberg publishes a separate
runtime jar per Spark minor version. If no jar exists for a Spark minor, that
Spark cannot read or write Iceberg at all. Spark 4.0.1 with
`iceberg-spark-runtime-4.0_2.13:1.11.0` is a published, well-trodden pairing,
and the Spark Operator 2.5.0 examples use 4.0.x. Spark 4 is Scala 2.13 only,
hence the `_2.13` suffix.

**Airflow ↔ PostgreSQL — why RDS is on 17.** Airflow 3.2 supports PostgreSQL
13–17 for its metadata database. RDS may default to a newer major version, so
`engine_version = "17"` is set explicitly (major only, so RDS still applies
minor updates). Polaris and Harbor share the instance and are fine on 17.

**Trino ↔ its chart.** The chart lags the Trino release train. Chart 1.42.2
ships `appVersion: "480"`; Trino 480 runs. Trino needs
`fs.native-s3.enabled=true` because the legacy Hadoop S3 filesystem was removed.

**Harbor's S3 driver ↔ Pod Identity.** Harbor's registry storage driver does not
use the Pod Identity credential chain, which is why it is the one component with
a static, single-bucket IAM key (see
[DATA_GOVERNANCE.md](DATA_GOVERNANCE.md#3-workload-access-to-aws--pod-identity)).

**Kubernetes version.** EKS stays on a version in **standard** support. Extended
support costs six times as much per hour for the control plane
([COST.md](COST.md)).

## 4. Why this stack, one line each

- **Iceberg** — open table format; storage separate from compute, readable by any engine.
- **Polaris over other REST catalogs** — Apache project with role-based grants and scoped credential vending built in, so access control is a property of the catalog rather than something bolted on. `tabulario/iceberg-rest` has neither; Nessie solves branching, which this platform does not need; AWS Glue would tie the catalog to one cloud.
- **Trino** — mature Iceberg connector, resource groups for workload isolation, standard JDBC for BI tools.
- **Spark on Kubernetes via the operator** — mature Iceberg writer (`MERGE`, `UPDATE`, `DELETE`); short-lived pods suit Spot.
- **Airflow with KubernetesExecutor** — no Celery broker and no standing workers; each task is a pod that exits when done.
- **RDS over PostgreSQL in the cluster** — the catalog database is critical state; managed backups remove that risk for a small fixed cost.
- **S3 over MinIO** — no storage to operate, effectively unlimited, cheaper per GB than EBS.
- **Argo CD** — the apps repository is the definition of the cluster; rollback is a `git revert`.
- **Harbor** — images stay inside the VPC, access-controlled per project (robot accounts per use), with vulnerability scanning available when enabled; pod start-up does not depend on a public registry.
- **Self-hosted runners (ARC)** — runners reach Harbor over the private network, so nothing is exposed; they scale to zero between builds.
- **Karpenter over Cluster Autoscaler** — picks instance types per pending pod and removes empty nodes quickly, which is what makes Spot-at-zero work.
- **Tailscale over a public ALB with an IP allowlist** — identity per device and user instead of per address; no public endpoint at all.
- **Secrets Manager + Kubernetes Secret** — enough for static credentials; Vault is the planned upgrade below.

## 5. Planned upgrades

Deferred, not rejected. Each has the condition that would trigger it.

### HashiCorp Vault — dynamic credentials

**Adds:** short-lived database users per pod instead of shared static
passwords, a per-read audit log, per-secret policy. The Vault Secrets Operator
syncs into native Kubernetes Secrets, so no application manifest changes.

**Why not yet:** Vault is stateful and must be highly available; a single
replica with manual unseal is less reliable than the secrets it guards, and
when Vault is down no pod can start.

**Trigger:** credentials need to rotate on a schedule, a requirement appears for
read-level audit, or several teams need different subsets.

**Do first, cheaply:** EKS envelope encryption with a KMS key, and RBAC that
withholds `get secrets` from everything but the workload ServiceAccount. A
lighter middle step is External Secrets Operator plus Secrets Manager rotation.

### Grafana Mimir — long-term metrics

**Adds:** Prometheus `remote_write`s into Mimir, which stores blocks in S3:
unbounded retention at S3 prices, a second Prometheus replica becomes possible
(Mimir de-duplicates), downsampling for long queries. Grafana speaks the same
query API, so no dashboard is rewritten.

**Why not yet:** seven days answers today's questions (did last night's run slow
down, was the cluster full when a driver was Pending), and Mimir is several
stateful components to run.

**Trigger:** a question seven days cannot answer comes up twice, or capacity
planning needs month-over-month numbers. Start with the single-binary mode.
If the cluster stays at one Prometheus and cost is the constraint, Thanos
(sidecar uploading blocks) is the lighter answer.

### Others in `BACKLOG.md`

Spark History Server (event logs already land in `logs/spark-events/`), Airflow
email alerts, a dedicated Polaris principal for Trino, Tailscale ACLs, Terraform
state in S3.

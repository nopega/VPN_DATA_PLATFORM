# 10_airflow

Airflow's AWS identity: write and read task logs under `s3://<logs>/airflow/`,
nothing else. Airflow itself is in the apps repository (`apps/airflow.yaml`).

| Creates | Why |
|---|---|
| role `vpn-data-platform-airflow` + inline policy | `s3://<logs>/airflow/*` only |
| 5 Pod Identity associations in namespace `airflow` | api-server, scheduler, dag-processor, triggerer, worker |

Pod Identity matches exact ServiceAccount names. If a chart upgrade adds a
component that writes logs, add its ServiceAccount to
`airflow_service_accounts` -- otherwise its logs fail with AccessDenied.

## Apply

```bash
terraform init
terraform plan     # expect: 7 to add
terraform apply
cd ../.. && ./bootstrap/airflow.sh
```

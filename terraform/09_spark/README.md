# 09_spark

Spark's own AWS identity. The Spark operator, the namespace and the jobs are
in the apps repository (`apps/spark-operator.yaml`, `workloads/spark`,
`runs/`).

| Creates | Why |
|---|---|
| role `vpn-data-platform-spark` + Pod Identity association `spark/spark` | driver and executor pods |
| inline policy: `s3://<logs>/spark-events/*` only | event logs, for the history server |
| empty object `spark-events/` in the logs bucket | Spark will not start if `spark.eventLog.dir` does not exist |

No warehouse access: tables are written with credentials Polaris vends to
principal `etl` (made by `bootstrap/spark.sh`). Reasoning at the top of
`main.tf`.

Stage 06 was changed alongside this one: the logs bucket's 30-day expiry now
skips zero-byte objects, so the `spark-events/` marker is never expired.
Apply 06 first (expect `1 to change`).

## Apply

```bash
cd ../06_data_foundation && terraform plan && terraform apply
cd ../09_spark
terraform init
terraform plan     # expect: 4 to add
terraform apply
terraform output
```

## Then

```bash
cd ../..
./bootstrap/spark.sh
```

# Tear down and rebuild

Two ways to stop paying for the platform, and how to bring it back from each.

| | Park | Destroy |
|---|---|---|
| How | `scripts/scale.sh down` | `terraform destroy`, every stage |
| Cost while off | ~\$3.8/day | ~\$7.2/month (Secrets Manager only) |
| Back with | `scripts/scale.sh up`, minutes | sections 3–4 below, about 1.5–2 hours |
| Kept | everything: tables, images, DAG history, secrets | secrets only |

Park for days or weeks. Destroy when it will be off for longer than the
rebuild is worth. AWS starts a stopped RDS instance again after 7 days, so a
parked platform needs `scale.sh down` re-run weekly.

All commands assume Tailscale is connected and you are in the repository root.

## 1. Why the order matters

Several AWS resources are not created by Terraform but by controllers running
**inside** the cluster. Delete the cluster first and those controllers die
with it — nothing is left to remove what they made, and Terraform never knew
about it.

| Created by | In AWS | Left behind if the cluster goes first |
|---|---|---|
| AWS Load Balancer Controller (from Ingress) | ALB, target groups, security groups | ALB keeps billing; VPC destroy fails with `DependencyViolation` |
| EBS CSI driver (from PersistentVolumeClaims) | EBS volumes | volumes keep billing |
| Karpenter (from NodePools) | EC2 instances | instances keep running unmanaged |
| external-dns | Cloudflare records | harmless; updated on the next build |

Terraform also needs the cluster while destroying: stages 04, 05, 07 and 11
uninstall Helm releases through the Kubernetes API.

**Rule: whoever created it deletes it, while it is still alive.**

## 2. Destroy

### 2.1 Bring it up if parked

Controllers need nodes to clean up after themselves.

```bash
./scripts/scale.sh up
./scripts/scale.sh status
```

### 2.2 CI runners

```bash
(cd terraform/11_ci && terraform destroy)
```

### 2.3 Everything Argo CD manages — one command

`root` carries the cascade finalizer, so deleting it deletes every
Application under it, and each of those deletes what it deployed.

```bash
kubectl delete application root -n argocd       # takes several minutes
```

StatefulSets do **not** delete their PersistentVolumeClaims (by Kubernetes
design), and Harbor's chart keeps its jobservice claim on purpose. Remove
them while the EBS CSI driver is still running:

```bash
kubectl delete pvc -A --all
```

All of these must be empty before going on:

```bash
kubectl get applications -n argocd
kubectl get ingress -A
kubectl get pvc -A
kubectl get nodeclaims
```

### 2.4 Harbor's access key, and the buckets

`bootstrap/harbor.sh` created the access key, not Terraform, so the IAM user
cannot be deleted until the key is. Buckets have `force_destroy = false`, so
they must be emptied deliberately.

```bash
U=vpn-data-platform-harbor-registry
for k in $(aws iam list-access-keys --user-name $U --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --user-name $U --access-key-id $k
done

for b in warehouse logs registry; do
  aws s3 rm s3://vpn-data-platform-$b-126052242139 --recursive
done
```

Anything worth keeping in the warehouse: `aws s3 sync` it somewhere first.
Tables can otherwise be rebuilt by re-running the DAGs.

### 2.5 Stages 10 to 05

```bash
cd terraform
for s in 10_airflow 09_spark 08_registry 07_karpenter 06_data_foundation 05_argocd; do
  (cd $s && terraform destroy) || break
done
```

`06` takes longest: RDS deletion, 5–10 minutes, **no final snapshot**.

### 2.6 Ingress

The Cloudflare provider needs its token in this terminal. While the cluster
still exists it can be read from external-dns's Secret:

```bash
export CLOUDFLARE_API_TOKEN=$(kubectl get secret cloudflare-api-token -n external-dns \
  -o jsonpath='{.data.api-token}' | base64 -d)

cd 04_ingress
kubectl delete -f smoke-test.yaml --ignore-not-found
terraform destroy
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'   # must be []
```

### 2.7 Cluster, router, VPC

```bash
cd ../03_eks && terraform destroy               # ~10 min; kubectl stops working after this
cd ../02_tailscale_router && terraform destroy
cd ../01_vpc && terraform destroy
```

A `DependencyViolation` on `01_vpc` means something created by a controller
is still in a subnet — find it before retrying.

### 2.8 Check for leftovers

zsh does not accept `#` comment lines pasted together with commands; paste
these without comments.

```bash
aws ec2 describe-instances --filters Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId'
aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 describe-addresses --query 'Addresses[].PublicIp'
aws eks list-clusters
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupName'
aws s3 ls | grep vpn-data-platform
```

All empty. An `available` volume tagged `KubernetesCluster=vpn-data-platform`
is a forgotten PersistentVolumeClaim: `aws ec2 delete-volume --volume-id <id>`.

Outside AWS:

- **Tailscale admin → Machines:** delete the offline `vpn-data-platform-router`.
- **Cloudflare:** service records stay, pointing nowhere. Harmless; external-dns
  updates them on the next build.

### 2.9 What survives

`vpn-data-platform/*` in Secrets Manager (~\$0.40 each per month) and the local
`terraform.tfstate` files (empty now, but `apply` needs them — do not delete).

Two of the kept secrets are dead after a destroy:

- `harbor-s3` — its access key was deleted in 2.4
- `harbor-robot-*` — the robot accounts lived in Harbor's database, which went
  with RDS

If a bootstrap script fails on one of them, delete that secret and re-run the
script; it creates a new one.

To go to \$0, delete every secret **except** `vpn-data-platform/tailscale-auth-key`
(stage 02 reads it):

```bash
for s in $(aws secretsmanager list-secrets --query 'SecretList[].Name' --output text); do
  case "$s" in
    vpn-data-platform/tailscale-auth-key) continue ;;
    vpn-data-platform/*) aws secretsmanager delete-secret --secret-id "$s" --force-delete-without-recovery >/dev/null && echo "deleted $s" ;;
  esac
done
```

Then revoke the GitHub token the runners used (GitHub → Settings → Developer
settings → Personal access tokens).

## 3. Before rebuilding

- **Tailscale auth key** (`vpn-data-platform/tailscale-auth-key`): must be
  reusable and not expired — Tailscale admin → Settings → Keys. If expired,
  generate a new reusable, pre-approved key and update the secret:
  `aws secretsmanager put-secret-value --secret-id vpn-data-platform/tailscale-auth-key --secret-string '<key>'`
- **Cloudflare API token:** have one ready (Edit zone DNS, zone `nopega.net`).
- **GitHub token** for the runners, if it was revoked.
- The old router machine is deleted from Tailscale (2.8).

## 4. Rebuild

Each stage: `cd terraform/<stage> && terraform init && terraform apply`.
Bootstrap scripts are in `bootstrap/`; their order and prerequisites are in
[bootstrap/README.md](../bootstrap/README.md).

| # | Stage | Then |
|---|---|---|
| 1 | `01_vpc` | — |
| 2 | `02_tailscale_router` | Tailscale admin → Machines → router → **approve route** `10.42.0.0/16`; check `ping 10.42.0.2` |
| 3 | `03_eks` (~15 min) | `aws eks update-kubeconfig --name vpn-data-platform --region ap-southeast-1`. Split DNS in Tailscale is already set and needs nothing |
| 4 | `04_ingress` | **before apply:** create Secret `cloudflare-api-token` (key `api-token`) in namespace `external-dns`, and `read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN` |
| 5 | `05_argocd` | Argo CD starts deploying everything in the apps repository. Applications whose secrets do not exist yet fail and retry — expected until the steps below are done |
| 6 | `06_data_foundation` | `polaris.sh` → `polaris_catalog.sh` → `trino.sh` → `monitoring.sh` |
| 7 | `07_karpenter` | — |
| 8 | `08_registry` | `harbor.sh`, then create the Harbor project `ice-berg-platform` |
| 9 | `09_spark` | `spark.sh` (principal `etl`, the bronze / silver / gold namespaces) |
| 10 | `10_airflow` | `airflow.sh`; once the api-server pod is Running, `airflow.sh admin` |
| 11 | `ci.sh`, then `11_ci` | push a **new** tag, e.g. `git tag spark-v0.2.1 && git push origin spark-v0.2.1`, so CI rebuilds the Spark image into the empty Harbor; point `image_tag` in the DAG at it |
| 12 | data | Polaris starts empty, so no table exists. Trigger the DAGs (or backfill the days needed) to rebuild bronze → silver → gold |

### If an Application is stuck syncing

Terminate its operation, clear `operationState`, and restart the Argo CD
application controller:

```bash
kubectl patch application <name> -n argocd --type merge -p '{"operation":null}'
kubectl patch application <name> -n argocd --type json -p '[{"op":"remove","path":"/status/operationState"}]'
kubectl rollout restart statefulset argocd-application-controller -n argocd
```

### Done when

```bash
kubectl get applications -n argocd     # all Synced / Healthy
./scripts/scale.sh status
```

and `https://trino.nopega.net`, `airflow`, `harbor`, `grafana` answer over Tailscale.

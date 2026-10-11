# 06_data_foundation

What the data components need from AWS before they can run: storage, a
database, and the permissions that connect Polaris to the storage. Nothing
here runs in the cluster; Polaris itself arrives next, through Argo CD.

| File | Creates |
|---|---|
| `s3.tf` | warehouse bucket (Iceberg), logs bucket (expires after 30 days); both private, encrypted, ACLs off |
| `rds.tf` | PostgreSQL 17 on db.t4g.micro, private subnets, master password kept by RDS in Secrets Manager |
| `iam.tf` | Polaris service role (Pod Identity, `polaris/polaris`) → storage role → warehouse `bronze/ silver/ gold/` only |

## Cost (ap-southeast-1)

| | per month |
|---|---|
| RDS db.t4g.micro, single zone | ~$18 |
| 20 GiB gp3 + 1 day of backups | ~$3 |
| master password secret | $0.40 |
| S3 | cents until data arrives |
| **total** | **~$21** |

## Same as the original, and different

Same: Postgres 17 on db.t4g.micro, one day of point-in-time recovery, a
warehouse and a logs bucket, Polaris reaching S3 through a separate storage
role limited to the medallion prefixes ("the path is the policy key").

Different:

- **The master password is never seen by Terraform.**
  `manage_master_user_password` makes RDS generate it and keep it in Secrets
  Manager. The original's script generated one and passed it around.
- **Pod Identity instead of IRSA** for the Polaris service role.
- **The logs bucket expires objects** (30 days). The original designed its
  lifecycle rules and never applied them.
- **Buckets carry the account id in their name**, so a name taken by any
  other AWS account can never collide.

## Apply

```bash
terraform init
terraform plan     # expect: 18 to add
terraform apply    # RDS takes ~5-10 minutes; the rest is seconds
```

## Check

```bash
terraform output

# Reach the database from the Mac over Tailscale (needs `brew install libpq`):
SECRET=$(terraform output -raw db_master_secret_arn)
export PGPASSWORD=$(aws secretsmanager get-secret-value --region ap-southeast-1 \
  --secret-id "$SECRET" --query SecretString --output text | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
$(brew --prefix libpq)/bin/psql "host=$(terraform output -raw db_address) dbname=platform user=dbadmin sslmode=require" -c 'select version();'
unset PGPASSWORD
```

A version string back proves the whole path: Mac → Tailscale → router →
private subnet → database security group → RDS.

## Next

Polaris through Argo CD. Before it can start it needs its own database and
user inside this instance (created with the master login above, once), and
that user's password as a Kubernetes Secret.

## Tear down

```bash
terraform destroy
```

Fails on a non-empty bucket, on purpose — `force_destroy` is off so the
warehouse is never deleted by accident. Empty a bucket deliberately
(`aws s3 rm s3://<bucket> --recursive`) if it really should go. The
database is deleted without a final snapshot (`skip_final_snapshot = true`);
flip that, and `deletion_protection`, before it holds anything you would
miss.

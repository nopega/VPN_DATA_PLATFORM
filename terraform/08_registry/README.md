# 08_registry

What Harbor needs from AWS. Harbor itself is applied by Argo CD from the apps
repository (`apps/harbor.yaml`).

| Creates | Why |
|---|---|
| bucket `vpn-data-platform-registry-<account id>` | image layers; private, encrypted, ACLs off, only abandoned multipart uploads expire |
| IAM user `vpn-data-platform-harbor-registry` + inline policy | read/write that one bucket, nothing else |

No access key here: Terraform would keep its secret half in
`terraform.tfstate`. `bootstrap/harbor.sh` creates it and stores it in
Secrets Manager. Why a user and not Pod Identity is at the top of `main.tf`.

Pods reach the bucket through the S3 gateway endpoint from stage 01: no NAT,
no per-GB charge.

## Cost

Cents: S3 storage for the images pushed (about $0.025 per GiB-month).

## Apply

```bash
terraform init
terraform plan     # expect: 7 to add
terraform apply
terraform output
```

## Then

```bash
cd ../..
./bootstrap/harbor.sh
```

## Tear down

Delete Harbor first (`apps/harbor.yaml` out of the apps repo), delete the
access key (`aws iam delete-access-key ...`, otherwise destroy fails on the
user), then `terraform destroy`. The bucket refuses to go while it holds
images, on purpose.

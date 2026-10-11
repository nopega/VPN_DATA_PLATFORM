# vpn_data_platform

The Iceberg platform from the take-home (`ice-berg-platform`, kept in
`linemman_wong_nai_test/problem2_answer/`), rebuilt so that **nobody reaches
it from the open internet**. Users join a Tailscale network instead, and the
load balancer becomes internal.

## Why

The original platform put one internet-facing Application Load Balancer in
front of every service and protected it with a source-address allowlist. That
broke three times, each time because a home router picked up a new public
address — see the domain-unreachable runbook from the original build. An allowlist also
cannot scale past one person: every user's address changes, and changes again
whenever they move between networks.

The fix is to check **who** someone is, not **where** they connect from.

```
before:  user ──internet──▶ ALB (public, allowlist) ──▶ pod
after:   user ──Tailscale──▶ subnet router in the VPC ──▶ ALB (internal) ──▶ pod
```

What changes as a result:

- The load balancer has no public address, so there is no allowlist to keep up to date.
- Adding a user means inviting them to the Tailscale network, nothing else.
- Nodes pull from Harbor inside the VPC instead of leaving through the NAT and
  coming back in through the public load balancer.
- Hostnames, the certificate and Cloudflare stay as they are. The names simply
  resolve to private addresses that only work for someone on Tailscale.

## Stages

Built with Terraform, one folder per stage, each applied on its own.

| Stage | What it creates | Cost while it exists | Status |
|---|---|---|---|
| `terraform/01_vpc` | VPC, subnets in 2 zones (as in the diagram), internet gateway, route tables, S3 gateway endpoint; NAT optional | **$0** (NAT off) | written |
| `terraform/02_tailscale_router` | one t4g.nano: Tailscale subnet router for `10.42.0.0/16` **and** NAT instance for the private subnets | ~$8.50/mo | written |
| `terraform/03_eks` | EKS 1.36, **private API endpoint only**, 1 × t3.xlarge on-demand, Spot group at 0, prefix delegation (110 pods/node) | ~$230/mo (control plane ~$73 + node ~$157) | written |
| `terraform/04_ingress` | wildcard certificate `*.nopega.net`, AWS Load Balancer Controller, external-dns; `smoke-test.yaml` proves the path | ~$18/mo once an internal ALB exists | written |
| `terraform/05_argocd` | Argo CD v3.5.0 at `argocd.nopega.net`, on the shared internal ALB | $0 extra (shares the ALB) | written |
| `argocd/` | app-of-apps: `root.yaml` (applied once) watches `argocd/apps/` in this repository | — | running (smoke-test) |
| `terraform/06_data_foundation` | warehouse + logs buckets, RDS PostgreSQL 17, Polaris IAM roles (Pod Identity) | ~$21/mo | written |
| later | Polaris, Trino, monitoring, Airflow, Spark operator, Harbor — as Argo CD Applications | — | not started |

Known gaps and their deadlines: [BACKLOG.md](BACKLOG.md).

### How private subnets reach the internet

Private subnets have no route to the internet until something gives them one.
Nodes need it to pull public images. Decision: the Tailscale router in stage
02 doubles as a NAT instance (~$8.50/mo for both jobs) instead of the managed
NAT gateway (~$47/mo in Singapore, $0.059/hr + public address, plus
$0.045/GB). The cost of that choice is one machine as a shared point of
failure for the way in and the way out. The NAT gateway remains available as
`enable_nat_gateway = true` in stage 01 (with `act_as_nat = false` in 02).

Destroy stages in reverse order: 06, 05, 04, 03, 02, then 01 — and before 04, delete
every Ingress (`kubectl delete -f smoke-test.yaml`), or its ALB is orphaned.

## Running a stage

```bash
cd terraform/01_vpc
terraform init
terraform plan        # read it: with the defaults, nothing in it should cost money
terraform apply
terraform output subnet_layout

terraform destroy     # when finished
```

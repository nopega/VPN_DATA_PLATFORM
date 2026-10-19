# Cost

What the platform costs to run, what it costs parked, and every design
decision that was made for money.

> **These are estimates**, worked out from AWS on-demand list prices for
> `ap-southeast-1` (Singapore) at the time of writing, 730 hours a month, before
> tax and without free-tier credit. Prices change — check the
> [AWS Pricing Calculator](https://calculator.aws/) and Cost Explorer for real
> numbers.

The pattern worth noticing: **compute is the visible half of the bill and
rarely the surprising one.** You choose the instance type, so you know what it
costs. Data movement and idle managed services accrue quietly under line items
nobody checks — which is why two of the decisions below are about a NAT and a
load balancer, not about a smaller node.

## 1. Running cost (everything up)

| Item | Monthly | Note |
|---|---|---|
| EKS control plane | ~\$73 | \$0.10/hour while the version is in standard support |
| Managed node group, 1 × `t3.xlarge` On-Demand | ~\$154 | system pods and the stateful platform services |
| Karpenter `general` nodes | \$0 – \$154 each | only when pending pods do not fit; removed again when empty |
| Karpenter `spot-batch` nodes | ~\$0 idle | Spark and CI runners only; exist for the minutes a job runs |
| Tailscale router `t4g.nano` + public IPv4 | ~\$8 | also replaces the NAT gateway (section 3) |
| RDS `db.t4g.micro` PostgreSQL 17, 20 GB, single-AZ | ~\$21 | instance ~\$18 + storage ~\$3; Polaris, Harbor and Airflow share it |
| Internal ALB (one, shared) | ~\$18 – \$22 | hourly charge plus a small capacity-unit charge |
| Secrets Manager, ~19 secrets | ~\$7.60 | \$0.40 per secret per month; API calls negligible |
| EBS: node root disks (30 / 50 GiB) + PersistentVolumeClaims | ~\$10 | gp3; Prometheus alone has 20 Gi |
| S3: warehouse, logs, registry | a few \$ | grows with data; requests dominate at this size |
| **Total, one system node, no batch running** | **~\$290 / month** | **≈ \$9.7 / day** |

## 2. Parked cost (`scripts/scale.sh down`)

`scale.sh down` saves the Karpenter NodePool limits, sets them to zero, scales
every managed node group to zero and stops RDS. What keeps billing:

| Item | Monthly |
|---|---|
| EKS control plane | ~\$73 |
| Internal ALB (the Ingress objects still exist) | ~\$18 |
| Tailscale router (left running so the tailnet still reaches the VPC) | ~\$8 |
| Secrets Manager | ~\$7.60 |
| EBS volumes behind PersistentVolumeClaims, RDS storage, S3 | ~\$8 |
| **Total parked** | **~\$115 / month ≈ \$3.8 / day** |

`scale.sh up` reverses it in order: start RDS, restore node groups, restore the
saved NodePool limits, then restart Argo CD so everything reconciles. Helm
releases, volumes and databases survive, so coming back is one command rather
than a reinstall.

Two things to know:

- **AWS restarts a stopped RDS instance automatically after 7 days.** A cluster
  parked for longer needs `scale.sh down` run again (or the instance stopped
  again) once a week.
- **Deleting everything** (`terraform destroy`, stages in reverse order) is the
  only way to reach zero; the control plane and ALB alone are most of the parked
  bill.

## 3. The decisions made for money

### A Tailscale router as NAT, not a NAT gateway

A managed NAT gateway is about \$43/month per availability zone in Singapore
**plus \$0.059 per GB processed**. The `t4g.nano` subnet router already has to
exist for Tailscale, so it also does NAT for the private subnets: one instance,
two jobs, ~\$8/month.

The trade is availability: one small instance in one zone. If it stops, pods
lose internet egress (image pulls from public registries, GitHub) and people
lose the tailnet route. Nothing inside the VPC — S3, RDS, the ALB — depends on
it.

### An S3 gateway endpoint

S3 is the storage layer, so most bytes the platform moves are S3 bytes. A
**gateway** VPC endpoint has no hourly and no per-GB charge and routes that
traffic straight out of the subnet, so none of it goes through the NAT. Behind
a NAT gateway, a single 1 TB scan would cost about \$59 in processing — billed
under *NAT Gateway*, not under *S3*, which is where nobody looks.

### One ALB for every hostname

Every Ingress carries the same `group.name` (`vpn-data-platform-internal`), so
the controller merges them into one load balancer: one ALB, one wildcard
certificate, one host rule per service. Six separate ALBs would be roughly
\$110 – \$130/month instead of ~\$20.

### Karpenter, and Spot at zero

Spark executors and CI runners go only to the `spot-batch` NodePool. Spot is
typically 60–70% cheaper, but the discount only matters if the capacity also
**disappears when idle** — Karpenter consolidates empty nodes away, so a pipeline
that runs for a few minutes a day costs a few minutes of Spot a day. Karpenter
also picks the instance type per pending pod, instead of a fixed node group
shape that is either too small or wasted.

### Runners that cost nothing when idle

The Actions Runner Controller scale set runs **0–2** runners. With no job
queued there is no runner pod and therefore no node for it. A 4.5-minute image
build costs a few cents of Spot.

### Parking, not just scaling

The biggest saving for a platform that is not used around the clock is turning
it off: running ~\$9.7/day versus parked ~\$3.8/day. `scale.sh` makes that
safe to do every evening (section 2).

### Kubernetes kept in standard support

The EKS control plane is \$0.10/hour in standard support and **\$0.60/hour** in
extended support — ~\$73 versus ~\$438 a month for the same cluster. The
version is set explicitly in `terraform/03_eks` and is upgraded before its
standard support ends, rather than left to drift into the expensive tier.

### Small fixed sizes where state lives

One `db.t4g.micro` single-AZ RDS instance with 1-day backups serves three
applications; a separate instance each would triple the fixed cost. Multi-AZ
would roughly double it and is the first thing to change if the platform holds
data someone depends on.

## 4. Watching the bill

- **Cost Explorer**, grouped by service, shows each bucket and the RDS, EKS and
  EC2 charges separately; separate buckets per kind of data mean storage costs
  split without tagging ([DATA_TIER.md](DATA_TIER.md)).
- An **AWS Budget** with an email alert at a fixed monthly amount is the cheapest
  guard against a forgotten `scale.sh up`.
- Billing metrics in CloudWatch exist only in `us-east-1`, whatever region the
  resources are in, and only after *Receive CloudWatch billing alerts* is turned
  on in Billing preferences.

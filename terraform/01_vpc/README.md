# 01_vpc

The network every later stage is built into. Free with the defaults.

## What it creates

| Resource | Count | Cost |
|---|---|---|
| VPC `10.42.0.0/16` | 1 | $0 |
| public subnet `/24` | 1 per zone | $0 |
| private subnet `/19` | 1 per zone | $0 |
| internet gateway | 1 | $0 |
| route tables | 1 public, 1 private per zone | $0 |
| S3 gateway endpoint | 1 | $0 |
| default security group, emptied | 1 | $0 |
| NAT gateway + its public address | 0, or 1 with `enable_nat_gateway = true` | ~$47/mo + $0.045/GB (Singapore) |

## Decisions worth knowing

**The address range is chosen, not defaulted.** The original platform let
eksctl pick `192.168.0.0/16`, the same range most home routers use. Once
Tailscale routes the VPC range to a user's laptop, an overlap means the laptop
cannot tell "my printer at 192.168.1.20" from "a pod at 192.168.1.20".
`10.42.0.0/16` avoids both home ranges and the common office `10.0.0.0/16`.

**Private subnets are big.** Pods take real VPC addresses, so a node with 20
pods uses 21 addresses. A `/19` per zone leaves room for the cluster to grow
without re-addressing.

**Subnet tags decide where load balancers go.**
`kubernetes.io/role/elb` on public subnets, `kubernetes.io/role/internal-elb`
on private ones. The VPN design puts the load balancer in the private ones.

**Public subnets do not hand out public addresses.** `map_public_ip_on_launch
= false`, so an instance placed there by mistake is not exposed by accident.

**The default security group is emptied.** Anything that forgets to name a
security group gets no access rather than "everything inside the group".

## Checking it after apply

```bash
terraform output subnet_layout
aws ec2 describe-route-tables --region ap-southeast-1 \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'RouteTables[].{name:Tags[?Key==`Name`]|[0].Value,routes:Routes[].[DestinationCidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId]}'
```

Expect: the public table routes `0.0.0.0/0` to `igw-...`; each private table
has only `local` and the S3 prefix list (plus `0.0.0.0/0` to `nat-...` only
when the NAT is enabled).

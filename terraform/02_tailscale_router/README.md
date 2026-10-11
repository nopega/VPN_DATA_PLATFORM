# 02_tailscale_router

One `t4g.nano` in public subnet 1a doing two jobs:

- **Tailscale subnet router** — advertises `10.42.0.0/16`, so a laptop on
  Tailscale reaches private addresses inside the VPC.
- **NAT instance** — the private subnets' `0.0.0.0/0` route points at it,
  replacing the ~$47/month NAT gateway.

```
laptop ══Tailscale══▶ router (10.42.0.x) ──▶ anything in 10.42.0.0/16
node (private) ──────▶ router ──▶ internet gateway ──▶ internet
```

About **$8.50/month** in ap-southeast-1: instance ~$3.70, public IPv4 ~$3.65,
disk ~$0.80, secret $0.40.

**Trade-off, stated plainly:** one machine, two jobs. If it stops, users lose
the way in *and* private subnets lose the way out, at the same moment.

## Before `apply` — one-time setup

### 1. Tailscale account and the Mac client

Sign up (the free Personal plan is enough), install Tailscale on the Mac and
log in. In the Mac app's menu, check that **Use Tailscale subnets** is on —
without it the Mac ignores the route the router advertises.

### 2. Generate an auth key

Admin console → **Settings → Keys → Generate auth key**:

| Option | Set to | Why |
|---|---|---|
| Reusable | **on** | changing the boot script rebuilds the instance, which logs in again |
| Ephemeral | **off** | ephemeral machines are removed when they go offline; a router must stay |
| Pre-approved | on (if device approval is enabled) | so the router does not wait for a click |
| Expiration | up to 90 days | the key is only for joining; the machine stays joined after it expires |

### 3. Put the key in Secrets Manager — not in Terraform

```bash
read -rs TS_KEY   # paste the tskey-auth-... value, press Enter (nothing is echoed)
aws secretsmanager create-secret --region ap-southeast-1 \
  --name vpn-data-platform/tailscale-auth-key \
  --secret-string "$TS_KEY"
unset TS_KEY
```

`read -rs` keeps the key out of your shell history. Terraform only looks up
this secret's ARN to grant the instance read access; the value never passes
through Terraform, so it never lands in `terraform.tfstate`.

## Apply

Stage 01 must already be applied (this stage reads `../01_vpc/terraform.tfstate`).

```bash
cd terraform/02_tailscale_router
terraform init
terraform plan     # expect: 11 to add (role, policy, attachment, profile,
                   #   security group + 3 rules, instance, 2 routes)
terraform apply
```

## After `apply`

### 4. Approve the route (once)

Admin console → **Machines → vpn-data-platform-router → ⋯ → Edit route
settings** → enable `10.42.0.0/16`.

On the same menu, **Disable key expiry** for this machine. Otherwise
Tailscale logs the router out after 180 days and the VPC silently becomes
unreachable.

### 5. Prove it works

From the Mac:

```bash
tailscale status                      # the router is listed and online
ping $(terraform output -raw private_ip)

# The VPC's own DNS resolver only answers queries from inside the VPC.
# Getting an answer from it proves packets really are routed into the VPC.
dig @10.42.0.2 sts.ap-southeast-1.amazonaws.com +short
```

The NAT side is only fully tested once something lives in a private subnet
(the EKS nodes in the next stage). Until then, check the router's own egress:

```bash
$(terraform output -raw shell)        # opens a shell on the router
curl -s https://checkip.amazonaws.com # should equal `terraform output public_ip`
sudo iptables -t nat -S POSTROUTING   # the MASQUERADE rule for 10.42.0.0/16
sudo tail -20 /var/log/router-bootstrap.log
```

## If something is wrong

| Symptom | Likely cause |
|---|---|
| Router never appears in `tailscale status` | auth key wrong, expired or already used (not reusable) — read the bootstrap log |
| Console output shows `Out of memory: Killed process ... (dnf)` | 0.5 GiB is not enough for dnf. The boot script now adds swap first; this happened on the first build, before that fix |
| Router online, `ping` times out | route not approved (step 4), or "Use Tailscale subnets" off on the Mac |
| `dig @10.42.0.2` times out but `ping` works | expected only if the route is approved but the Mac ignores subnets — same fix as above |
| Plan fails with "already has a NAT gateway" | stage 01 has `enable_nat_gateway = true`; turn one of them off |

## Tearing down

Destroy this stage **before** stage 01. Its routes sit in stage 01's route
tables and its security group sits in stage 01's VPC, so the VPC cannot be
deleted while they exist.

```bash
terraform destroy                                   # here first
cd ../01_vpc && terraform destroy                   # then the VPC
```

The secret is not managed by Terraform and stays (still $0.40/month) until
deleted by hand:

```bash
aws secretsmanager delete-secret --region ap-southeast-1 \
  --secret-id vpn-data-platform/tailscale-auth-key --force-delete-without-recovery
```

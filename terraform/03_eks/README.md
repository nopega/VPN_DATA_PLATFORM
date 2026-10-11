# 03_eks

EKS 1.36 in the private subnets, with **no public API endpoint**. `kubectl`
reaches the API server through Tailscale; nothing on the internet can.

Sized to come up and nothing more: one `t3.medium` on-demand node for system
pods, and a Spot group sitting at zero for Spark executors later.

## Cost while it exists (ap-southeast-1)

| | per hour | per month, left on |
|---|---|---|
| EKS control plane (standard support) | $0.10 | ~$73 |
| 1 × t3.xlarge on-demand (was t3.medium, see below) | $0.211 | ~$154 |
| 30 GiB gp3 on that node | | ~$3 |
| Spot group at 0 nodes | $0 | $0 |
| router from stage 02 | | ~$8.50 |
| **total** | | **~$238** |

**Why t3.xlarge.** The cluster came up on a t3.medium (4 GiB, ~3.3 GiB
allocatable). The first data component ruled it out: a Trino worker requests
4 GiB on its own — more than the whole node — so it would stay `Pending`
forever. 16 GiB holds Polaris, full-size Trino and monitoring.

The control plane bills from the moment it exists, whether or not anything
runs on it, and cannot be stopped — only deleted. `t3` instances run in
"unlimited" CPU-credit mode, so sustained high CPU can add a small charge on
top of the hourly price.

## Prefix delegation: 110 pods per node, not 17

A t3.medium can hold only 17 pod addresses in the default VPC CNI mode — the
first node hit that limit with system pods, the load balancer controller,
external-dns and Argo CD, while its CPU and memory were mostly idle. The
`vpc-cni` add-on runs with `ENABLE_PREFIX_DELEGATION=true`: each network
interface slot holds a /28 prefix (16 addresses) instead of one address, and
the managed node group sets max pods to 110 by itself.

It only applies to nodes launched after the setting, so node groups use a
name *prefix* with `create_before_destroy`: a change that needs new nodes
brings the new group up first, then drains and deletes the old one.

Check a node's limit:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,MAXPODS:.status.capacity.pods
```

## What is different from the original cluster

| | original (eksctl) | this stage |
|---|---|---|
| API endpoint | public **and** private | **private only** |
| Kubernetes | 1.34 (standard support ends 2 Dec 2026) | 1.36 (until Aug 2027) |
| After standard support ends | extended support, 6× the price | upgrades instead (`upgrade_policy`) |
| Who can use kubectl | IAM, via `aws-auth` ConfigMap | IAM, via EKS access entries |
| Pods assuming IAM roles | IRSA + OIDC provider | EKS Pod Identity |
| Core add-ons | unmanaged copies | managed add-ons, versioned by EKS |
| On-demand nodes | 5 × m5.large | 1 × t3.medium, raise as components arrive |

## Apply

Stages 01 and 02 must be applied, and **Tailscale must be connected** — the
final steps of this stage, and every `kubectl` afterwards, go over it.

```bash
cd terraform/03_eks
terraform init
terraform plan        # expect: 19 to add
terraform apply       # ~10 min for the control plane, ~3-5 more for the node
```

## One-time: Tailscale split DNS

With the public endpoint off, the cluster's hostname
(`<id>.sk1.ap-southeast-1.eks.amazonaws.com`) resolves **only through the
VPC's resolver, `10.42.0.2`**. Public DNS answers `no such host`, and kubectl
fails before it ever opens a connection.

Tailscale admin console → **DNS** → **Nameservers** → **Add nameserver →
Custom**:

| Field | Value |
|---|---|
| Nameserver | `10.42.0.2` |
| Restrict to domain (Split DNS) | on, `ap-southeast-1.eks.amazonaws.com` |

Only names under that domain go to the VPC resolver, over the tunnel; every
other lookup is untouched. The EKS *service* API
(`eks.ap-southeast-1.amazonaws.com`) is a different domain and is not
affected. Every device in the tailnet with "Use Tailscale DNS settings" on
gets this automatically.

Check before trying kubectl:

```bash
dig @10.42.0.2 <id>.sk1.ap-southeast-1.eks.amazonaws.com +short   # through the tunnel directly
dig <id>.sk1.ap-southeast-1.eks.amazonaws.com +short              # through split DNS
# both → 10.42.x.x
```

## Prove it works

```bash
$(terraform output -raw kubeconfig)
kubectl get nodes -o wide
kubectl get pods -A
```

**One `Ready` node proves three things at once:**

1. **The NAT side of the router works.** A node in a private subnet can only
   join after pulling its images and calling AWS APIs, all through the router.
   This is the test stage 02 could not run on its own.
2. **The API server is reachable privately.** The node talks to it inside the
   VPC.
3. **kubectl over Tailscale works.** The Mac reached the private endpoint
   through the router — the extra `api_access` security group is what lets it
   in.

And that the endpoint really is private:

```bash
dig +short $(terraform output -raw cluster_endpoint | sed 's|https://||')
# → 10.42.x.x addresses only
```

## If something is wrong

| Symptom | Likely cause |
|---|---|
| `dial tcp: lookup <id>.sk1.ap-southeast-1.eks.amazonaws.com: no such host` | split DNS not set up (section above), or "Use Tailscale DNS settings" off on this device |
| `kubectl` hangs, then `i/o timeout` | Tailscale disconnected, or the router is down — `tailscale status` |
| `kubectl` says `the server has asked for the client to provide credentials` | your current AWS identity is not the one that ran `apply`; add an access entry for it |
| Node group stuck `CREATING`, then `NodeCreationFailure` | nodes cannot get out: check the router (stage 02) and its NAT rule |
| `coredns` add-on `DEGRADED` | no Ready node yet; it settles once the node joins |

## Tear down

Reverse order — this stage first, then 02, then 01:

```bash
terraform destroy                    # here (~10 min)
cd ../02_tailscale_router && terraform destroy
cd ../01_vpc && terraform destroy
```

To stop paying for nodes but keep the cluster, scale `ng-ondemand` to 0
(`ondemand_min = 0`, `ondemand_desired = 0`). The control plane's ~$73/month
continues either way.

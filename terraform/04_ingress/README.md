# 04_ingress

How users reach services, end to end — still only over Tailscale.

```
laptop ══Tailscale══▶ router ──▶ internal ALB (private subnets) ──▶ pod
   │
   └─ test.nopega.net  ─CNAME─▶  internal-k8s-….elb.amazonaws.com  ─▶  10.42.x.x
      (written by external-dns)   (AWS publishes the private addresses
                                   of an internal load balancer publicly)
```

| Piece | What it does | Why it is here |
|---|---|---|
| ACM certificate `*.nopega.net` | TLS for every hostname | one wildcard instead of a fixed list re-requested every time a name is added |
| Cloudflare validation record | proves domain ownership to ACM | written by Terraform, not by importing a zone file |
| AWS Load Balancer Controller | turns Ingress objects into ALBs | same as the original, now with Pod Identity |
| external-dns | writes each Ingress hostname into Cloudflare | a rebuilt ALB with a new name no longer leaves DNS pointing at the old one |

Platform applications come later through Argo CD. This stage is the plumbing
underneath them, and `smoke-test.yaml` proves the plumbing before anything
heavy is installed.

## Cost

| | per month |
|---|---|
| internal ALB (only once an Ingress exists) | ~$18 + a little per traffic unit |
| certificate, controller, external-dns | $0 |

An internal ALB has no public IPv4 addresses, so none of the $3.65/month
per-address charge the original's internet-facing ALB carried.

## Before `apply` — one-time setup

### 1. A Cloudflare API token

Cloudflare dashboard → **My Profile → API Tokens → Create Token → Edit zone
DNS** template, Zone Resources: **Include → Specific zone → nopega.net**.

It is used twice: by Terraform (for the certificate's validation record) and by
external-dns (for hostnames). Neither path stores it in Terraform state.

### 2. Give it to Terraform — as an environment variable

```bash
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
```

The Cloudflare provider reads `CLOUDFLARE_API_TOKEN` from the environment.
It lasts for this terminal session only.

### 3. Give it to external-dns — as a Kubernetes Secret (Tailscale connected)

```bash
kubectl create namespace external-dns
kubectl -n external-dns create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN"
```

### 4. The zone ID

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: Cloudflare dashboard → nopega.net → Overview → "Zone ID"
```

## Apply

```bash
terraform init
terraform plan     # expect: 9 to add
terraform apply    # the certificate wait is usually 2-5 minutes
```

## Prove the whole path

```bash
kubectl apply -f smoke-test.yaml

kubectl -n smoke-test get ingress nginx -w     # wait for ADDRESS: internal-k8s-…  (~2-3 min)
dig +short test.nopega.net                     # CNAME, then 10.42.x.x   (~1-2 min after)
curl -sI https://test.nopega.net               # HTTP/2 200 from nginx
```

`200` here proves, in one request: Cloudflare DNS (written by external-dns) →
internal ALB name → private address → Tailscale route → router → ALB
security group → TLS with the wildcard certificate → host rule → pod.

And the negative test — turn Tailscale off and run the `curl` again. It must
time out: the name still resolves, but nothing outside the tailnet has a route
to `10.42.x.x`.

When done:

```bash
kubectl delete -f smoke-test.yaml              # removes the ALB (~1 min)
```

## If something is wrong

| Symptom | Likely cause |
|---|---|
| Ingress never gets an ADDRESS | controller log: `kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=40` |
| controller log: `no certificate found for host` | certificate not ISSUED yet, or the host is not under `nopega.net` |
| `dig test.nopega.net` returns nothing | external-dns log: `kubectl -n external-dns logs deploy/external-dns --tail=40` — wrong token or zone scope |
| external-dns log says the record exists and is not owned | a record with that name already exists in Cloudflare (left by the old platform); delete it by hand |
| `curl` times out with Tailscale ON | ALB targets unhealthy, or the ALB security group lacks `10.42.0.0/16` |
| `curl` returns 503 | no healthy target yet — wait a minute, then `kubectl -n smoke-test get pods` |

## Leftovers from the old platform

Cloudflare still has `trino`, `airflow`, `harbor`, `grafana`, `argocd`,
`prometheus` `.nopega.net` pointing at the deleted ALB. external-dns will not
touch them (no ownership record). Delete each by hand before its service
moves here; keep `ssh.nopega.net`.

## Tear down

```bash
kubectl delete -f smoke-test.yaml   # FIRST — or the ALB is orphaned
terraform destroy
```

The certificate's validation record is removed with the rest. DNS records
that external-dns wrote stay (upsert-only never deletes) — remove them in
Cloudflare if the hostnames are not coming back.

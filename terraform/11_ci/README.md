# 11_ci

GitHub Actions runners in the cluster (Actions Runner Controller 0.15.0), so a
workflow in `nopega/vpn-data-platform-apps` can build images and push them
to Harbor, which is only reachable from inside the VPC.

| Creates | Where |
|---|---|
| ARC controller | namespace `arc-systems`, on-demand node |
| runner scale set `vpn-data-platform` (0-2 runners, Docker-in-Docker) | namespace `arc-runners`; listener on-demand, runners on Karpenter Spot |

Nothing runs between jobs except the controller and the listener (two small
pods). A job starts a runner pod; Karpenter starts a Spot node for it and
removes it a minute after the job.

## Before

```bash
cd ../.. && ./bootstrap/ci.sh     # GitHub token Secret, Harbor robot, repo secrets
```

## Apply

```bash
terraform init
terraform plan     # expect: 2 to add
terraform apply
kubectl -n arc-systems get pods
kubectl -n arc-runners get pods     # one listener pod: ...-listener
```

GitHub → repository → Settings → Actions → Runners shows the scale set
`vpn-data-platform`.

## While the platform is scaled down

No nodes, so no runners: jobs wait in GitHub's queue and start once
`scripts/scale.sh up` brings the cluster back (or fail after 24 hours).

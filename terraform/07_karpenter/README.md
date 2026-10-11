# 07_karpenter

Nodes on demand. Karpenter watches for pods that cannot be scheduled,
launches an EC2 instance sized to fit them, and removes nodes that become
empty or underused.

| Here (Terraform) | In vpn-data-platform-apps (Argo CD) |
|---|---|
| controller IAM role (Pod Identity `kube-system/karpenter`) | `EC2NodeClass default` — image, subnets, security group, disk |
| SQS interruption queue + EventBridge rules | `NodePool general` — on-demand overflow, label `workload=critical` |
| `karpenter.sh/discovery` tags on private subnets and the cluster security group | `NodePool spot-batch` — Spot for Spark executors, label `workload=batch`, taint `spot=true:NoSchedule` |
| Karpenter 1.14.1 (LTS) Helm release, 1 replica, on the managed node | |

The managed node group from stage 03 stays as the always-on base; Karpenter
runs there and never on nodes it manages.

## Cost

Nothing fixed beyond a few cents for SQS and EventBridge. What it costs is the
nodes it launches — bounded by the NodePool `limits` (16 vCPU on-demand,
32 vCPU Spot) — and it removes them once idle (5 minutes on-demand, 1 minute
Spot).

## Apply

```bash
terraform init
terraform plan
terraform apply
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
```

Then enable the NodePools in the apps repo:

```bash
cd ~/Documents/vpn-data-platform-apps
mv next/karpenter-nodepools.yaml apps/
git add -A && git commit -m "Karpenter NodePools" && git push
kubectl get ec2nodeclass,nodepool
```

`EC2NodeClass default` must show `READY True` — that means Karpenter found
the subnets, the security group, the AMI and the role.

## Prove it scales

```bash
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.10 --replicas=0
kubectl set resources deployment inflate --requests=cpu=1,memory=1Gi
kubectl scale deployment inflate --replicas=6
kubectl get nodeclaims -w
```

A NodeClaim appears within seconds and a node joins in about a minute. Then:

```bash
kubectl delete deployment inflate
kubectl get nodeclaims -w
```

The extra node is removed about five minutes later.

Spot, the same way, with a pod that asks for it:

```bash
kubectl run spot-probe --image=public.ecr.aws/eks-distro/kubernetes/pause:3.10 \
  --overrides='{"spec":{"nodeSelector":{"workload":"batch"},"tolerations":[{"key":"spot","value":"true","effect":"NoSchedule"}]}}'
kubectl get nodeclaims -o wide
kubectl delete pod spot-probe
```

## The managed ng-spot group

Redundant now: `spot-batch` does its job and can actually scale. Remove it
from stage 03 once Spark runs on Karpenter's Spot nodes (BACKLOG).

## Tear down

Remove the NodePools first (delete `apps/karpenter-nodepools.yaml` and push),
so Karpenter terminates the nodes it launched; then `terraform destroy` here.
Destroying the controller first leaves its nodes running with nothing to
remove them.

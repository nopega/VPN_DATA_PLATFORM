#!/usr/bin/env bash
#
# scripts/scale.sh down|up|status -- park the platform when nobody uses it.
#
#   down   no EC2 worker nodes, RDS stopped
#   up     nodes and RDS back; Argo CD puts everything else back from git
#
# What keeps running (and billing) while down, by design:
#   EKS control plane ~$0.10/h, internal ALB ~$0.025/h, Tailscale router
#   (t4g.nano, so kubectl and this script still work), EBS volumes, S3,
#   RDS storage. Roughly $3.50/day instead of $8+/day.
#
# Domains need nothing on the way back up: they point at the internal ALB,
# which stays, and the VPN path does not depend on any home IP. That was the
# whole reason for this rebuild.
#
# ORDER MATTERS ON THE WAY DOWN
# -----------------------------
# 1. Argo CD's controller stops first. Otherwise self-heal undoes step 2
#    within seconds (the NodePools are in git).
# 2. Karpenter's NodePools get a CPU limit of 0, then its nodes are deleted.
#    Karpenter must still be running for this: it drains and terminates its
#    own nodes, and with a limit of 0 it launches no replacements.
# 3. Managed node groups to 0. Karpenter itself lives here and goes last.
# 4. RDS stopped. AWS starts a stopped instance again after 7 days on its
#    own -- run `down` again, or it bills as running from then on.
#
# On the way up the reverse: RDS, managed nodes, then Argo CD, which restores
# the NodePool limits from git and every app with them. Pods that need the
# database restart until RDS is available; that is expected.
#
# Needs: aws, kubectl, Tailscale connected.

set -euo pipefail

REGION="ap-southeast-1"
CLUSTER="vpn-data-platform"
DB="vpn-data-platform-db"
MODE="${1:-status}"
ANN="vpn-data-platform/limits-before-down"
ANN_JP="$ANN"   # no dots in the key, so usable in jsonpath as is

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }
need aws; need kubectl

nodegroups() { aws eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER" --query 'nodegroups[]' --output text; }
ng_max() { aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$1" \
  --query 'nodegroup.scalingConfig.maxSize' --output text; }
db_state() { aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB" \
  --query 'DBInstances[0].DBInstanceStatus' --output text; }

status() {
  echo "== node groups"
  for ng in $(nodegroups); do
    aws eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
      --query 'nodegroup.[nodegroupName,scalingConfig.minSize,scalingConfig.desiredSize,scalingConfig.maxSize,status]' --output text
  done
  echo "== RDS: $(db_state)"
  echo "== nodes"
  kubectl get nodes 2>/dev/null || echo "(cluster API not reachable)"
}

case "$MODE" in
status)
  status
  ;;

down)
  echo "[1/4] stop Argo CD's controller (so self-heal does not undo the next step)"
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=0

  echo "[2/4] Karpenter: no new nodes, remove the ones it made"
  for np in $(kubectl get nodepools -o name); do
    # Remember the real limits on the object itself: `up` puts them back
    # BEFORE Argo CD returns. Argo CD alone is not enough -- its own
    # controller may need a Karpenter node to start on, and with cpu=0 there
    # would never be one.
    # Skip if already saved, or already parked (cpu=0 is not worth saving).
    if [ -z "$(kubectl get "$np" -o jsonpath="{.metadata.annotations.$ANN_JP}")" ] \
       && [ "$(kubectl get "$np" -o jsonpath='{.spec.limits.cpu}')" != "0" ]; then
      kubectl annotate "$np" --overwrite "$ANN=$(kubectl get "$np" -o jsonpath='{.spec.limits}')" >/dev/null
    fi
    kubectl patch "$np" --type merge -p '{"spec":{"limits":{"cpu":"0"}}}' >/dev/null
    echo "      $np limit cpu=0"
  done
  if [ -n "$(kubectl get nodeclaims -o name)" ]; then
    kubectl delete nodeclaims --all --wait=true --timeout=10m
  fi
  echo "      no Karpenter nodes left"

  echo "[3/4] managed node groups -> 0"
  for ng in $(nodegroups); do
    aws eks update-nodegroup-config --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
      --scaling-config "minSize=0,desiredSize=0,maxSize=$(ng_max "$ng")" >/dev/null
    echo "      $ng -> 0"
  done

  echo "[4/4] RDS"
  case "$(db_state)" in
    available) aws rds stop-db-instance --region "$REGION" --db-instance-identifier "$DB" >/dev/null
               echo "      stopping (AWS restarts it by itself after 7 days)" ;;
    *)         echo "      state $(db_state) -- left alone" ;;
  esac

  echo ""
  echo "Down. Nodes drain over the next few minutes: $0 status"
  ;;

up)
  echo "[1/4] RDS"
  case "$(db_state)" in
    stopped)   aws rds start-db-instance --region "$REGION" --db-instance-identifier "$DB" >/dev/null
               echo "      starting" ;;
    *)         echo "      state $(db_state)" ;;
  esac

  echo "[2/4] managed node groups"
  for ng in $(nodegroups); do
    # The always-on group back to 1; the old managed Spot group stays at 0
    # (Karpenter's spot-batch NodePool replaced it).
    case "$ng" in
      ng-ondemand-*) size=1 ;;
      *)             size=0 ;;
    esac
    aws eks update-nodegroup-config --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
      --scaling-config "minSize=$size,desiredSize=$size,maxSize=$(ng_max "$ng")" >/dev/null
    echo "      $ng -> $size"
  done

  echo "[3/4] waiting for a Ready node (a few minutes)"
  for _ in $(seq 1 60); do
    if kubectl get nodes 2>/dev/null | grep -q ' Ready'; then break; fi
    sleep 10
  done
  kubectl get nodes

  echo "      Karpenter limits back"
  for np in $(kubectl get nodepools -o name); do
    saved="$(kubectl get "$np" -o jsonpath="{.metadata.annotations.$ANN_JP}")"
    case "$np" in
      */general)    fallback='{"cpu":"16","memory":"64Gi"}' ;;
      */spot-batch) fallback='{"cpu":"32","memory":"128Gi"}' ;;
      *)            fallback='' ;;
    esac
    limits="${saved:-$fallback}"
    [ -n "$limits" ] || { echo "      $np: no saved limits -- left for Argo CD"; continue; }
    kubectl patch "$np" --type merge -p "{\"spec\":{\"limits\":$limits}}" >/dev/null
    kubectl annotate "$np" "$ANN-" >/dev/null 2>&1 || true
    echo "      $np limits $limits"
  done

  echo "[4/4] start Argo CD's controller -- it re-applies everything else from git"
  kubectl -n argocd scale statefulset argocd-application-controller --replicas=1

  echo ""
  echo "Up. RDS takes 5-10 minutes; Polaris, Harbor and Airflow restart until it is available."
  echo "Check: $0 status ; kubectl -n argocd get applications"
  ;;

*)
  echo "usage: $0 down|up|status" >&2; exit 1 ;;
esac

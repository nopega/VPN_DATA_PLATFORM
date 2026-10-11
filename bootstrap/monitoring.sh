#!/usr/bin/env bash
#
# bootstrap/monitoring.sh -- Grafana's admin login, before the chart starts.
#
#   Secrets Manager  vpn-data-platform/grafana-admin-password
#   Kubernetes       monitoring/grafana-admin-credentials  {admin-user, admin-password}
#                    (the name the values file's grafana.admin.existingSecret expects)
#
#   ./monitoring.sh          create (reuses the password if it already exists)
#   ./monitoring.sh show     print the password

set -euo pipefail

REGION="ap-southeast-1"
SM_NAME="vpn-data-platform/grafana-admin-password"
NAMESPACE="monitoring"
K8S_SECRET="grafana-admin-credentials"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }
need aws; need kubectl; need openssl

sm_get() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$SM_NAME" --query SecretString --output text 2>/dev/null || true; }

if [ "${1:-}" = "show" ]; then sm_get; echo; exit 0; fi

kubectl get nodes >/dev/null 2>&1 || { echo "ERROR: kubectl cannot reach the cluster. Tailscale?" >&2; exit 1; }

PW="$(sm_get)"
if [ -z "$PW" ] || [ "$PW" = "None" ]; then
  PW="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  aws secretsmanager create-secret --region "$REGION" --name "$SM_NAME" \
    --description "Grafana admin password (grafana.nopega.net)" --secret-string "$PW" >/dev/null
  echo "new password saved to $SM_NAME"
else
  echo "reusing $SM_NAME"
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create secret generic "$K8S_SECRET" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$PW" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset PW

cat <<EOF
Done: $NAMESPACE/$K8S_SECRET
Next:
  1. Delete the old 'grafana' and 'prometheus' records in Cloudflare.
  2. In vpn-data-platform-apps: mv next/monitoring.yaml apps/ && git add -A && git commit && git push
Login: admin / \$($0 show)
EOF

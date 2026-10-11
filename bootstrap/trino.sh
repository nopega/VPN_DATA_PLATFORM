#!/usr/bin/env bash
#
# bootstrap/trino.sh -- the Secrets Trino needs before its pods start.
# Run from the Mac (Tailscale connected) after bootstrap/polaris_catalog.sh.
#
#   trino-polaris-credentials     POLARIS_OAUTH2_CREDENTIAL = <clientId>:<clientSecret>
#                                 (the Polaris root principal, as in the original)
#   trino-internal-communication  TRINO_INTERNAL_SHARED_SECRET (coordinator <-> workers)
#   trino-password-authentication password.db: bcrypt hashes for the three users
#                                 that rules.json in the chart grants access to
#
# Every value is created once in AWS Secrets Manager and reused after that,
# so re-running never changes a password someone is already using.
#
#   ./trino.sh                 create / refresh the Kubernetes Secrets
#   ./trino.sh show <user>     print one user's password (only on the machine that needs it)

set -euo pipefail

REGION="ap-southeast-1"
PREFIX="vpn-data-platform"
NAMESPACE="trino"
USERS=(etl_setup team_b_powerbi non_powerbi)   # must match accessControl rules.json

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found.$2" >&2; exit 1; }; }
need aws ""; need kubectl ""; need openssl ""; need python3 ""
need htpasswd " macOS ships it at /usr/sbin/htpasswd; otherwise: brew install httpd"

sm_get() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text 2>/dev/null || true; }
get_or_create() {   # name description
  local v; v="$(sm_get "$1")"
  if [ -n "$v" ] && [ "$v" != "None" ]; then printf '%s' "$v"; return; fi
  v="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
  aws secretsmanager create-secret --region "$REGION" --name "$1" --description "$2" --secret-string "$v" >/dev/null
  printf '%s' "$v"
}

if [ "${1:-}" = "show" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 show <user>" >&2; exit 2; }
  printf '%s\n' "$(sm_get "$PREFIX/trino-user-$2")"
  exit 0
fi

kubectl get nodes >/dev/null 2>&1 || { echo "ERROR: kubectl cannot reach the cluster. Tailscale?" >&2; exit 1; }
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "[1/3] Polaris credential for the iceberg catalog"
ROOT_JSON="$(sm_get "$PREFIX/polaris-root")"
[ -n "$ROOT_JSON" ] || { echo "ERROR: $PREFIX/polaris-root missing -- run bootstrap/polaris.sh" >&2; exit 1; }
CRED="$(printf '%s' "$ROOT_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["clientId"]+":"+d["clientSecret"])')"
unset ROOT_JSON
kubectl -n "$NAMESPACE" create secret generic trino-polaris-credentials \
  --from-literal=POLARIS_OAUTH2_CREDENTIAL="$CRED" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset CRED
echo "      ok"

echo "[2/3] internal shared secret"
SHARED="$(get_or_create "$PREFIX/trino-internal-shared-secret" \
  "Trino coordinator<->worker shared secret. Do not rotate while Trino is running.")"
printf '%s' "$SHARED" | kubectl -n "$NAMESPACE" create secret generic trino-internal-communication \
  --from-file=TRINO_INTERNAL_SHARED_SECRET=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset SHARED
echo "      ok"

echo "[3/3] password file for ${USERS[*]}"
DB=""
for u in "${USERS[@]}"; do
  pw="$(get_or_create "$PREFIX/trino-user-$u" "Trino password for $u")"
  DB+="$(printf '%s' "$pw" | htpasswd -i -n -B -C 10 "$u")"$'\n'
done
unset pw
printf '%s' "$DB" | kubectl -n "$NAMESPACE" create secret generic trino-password-authentication \
  --from-file=password.db=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset DB
echo "      ok"

cat <<EOF

Done. Next:
  1. Delete the old 'trino' record in Cloudflare (it points at the old ALB).
  2. In vpn-data-platform-apps: mv next/trino.yaml apps/ && git add -A && git commit && git push

Passwords live in Secrets Manager ($PREFIX/trino-user-<user>):
  $0 show etl_setup
EOF

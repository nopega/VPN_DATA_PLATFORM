#!/usr/bin/env bash
#
# bootstrap/polaris.sh -- one-time setup Polaris needs BEFORE its pod starts.
# Run from the Mac, with Tailscale connected, after terraform/06_data_foundation.
#
#   1. a database and a login of its own inside RDS   (iceberg_catalog / polaris)
#   2. that login as a Kubernetes Secret               (polaris/polaris-persistence)
#   3. the realm bootstrapped with a root principal    (polaris-admin-tool, one pod)
#
# Secrets go to AWS Secrets Manager first and to Kubernetes second, so the
# source of truth survives a cluster rebuild:
#   vpn-data-platform/polaris-db     {username, password, jdbcUrl}
#   vpn-data-platform/polaris-root   {realm, clientId, clientSecret, bootstrapped}
#
# Safe to re-run: every step checks what already exists.
#
# Needs: aws, kubectl, terraform, python3, openssl, and psql
#        (brew install libpq -- this script finds it even if not on PATH).

set -euo pipefail

REGION="ap-southeast-1"
PROJECT="vpn-data-platform"
REALM="vpn-data-platform"
NAMESPACE="polaris"
DB_NAME="iceberg_catalog"
DB_USER="polaris"
DB_SECRET="${PROJECT}/polaris-db"
ROOT_SECRET="${PROJECT}/polaris-root"
K8S_SECRET="polaris-persistence"
ADMIN_TOOL_IMAGE="apache/polaris-admin-tool:1.5.0"   # must match the server version

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF06="$REPO_ROOT/terraform/06_data_foundation"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }
need aws; need kubectl; need terraform; need python3; need openssl

PSQL="$(command -v psql || true)"
if [ -z "$PSQL" ] && command -v brew >/dev/null 2>&1; then
  PSQL="$(brew --prefix libpq 2>/dev/null)/bin/psql"
fi
[ -x "$PSQL" ] || { echo "ERROR: psql not found. brew install libpq" >&2; exit 1; }

json() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
secret_exists() { aws secretsmanager describe-secret --region "$REGION" --secret-id "$1" >/dev/null 2>&1; }
secret_get() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text; }
secret_put() {   # name json
  if secret_exists "$1"; then
    aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" --secret-string "$2" >/dev/null
  else
    aws secretsmanager create-secret --region "$REGION" --name "$1" --secret-string "$2" >/dev/null
  fi
}
genpw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }

echo "== Polaris bootstrap =============================================="

kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl cannot reach the cluster. Is Tailscale connected?" >&2; exit 1; }

DB_HOST="$(terraform -chdir="$TF06" output -raw db_address)"
MASTER_SECRET_ARN="$(terraform -chdir="$TF06" output -raw db_master_secret_arn)"
JDBC_URL="jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}?sslmode=require"
echo "database host: $DB_HOST"

# ---------------------------------------------------------------------------
# 1. Database and login
# ---------------------------------------------------------------------------
echo "[1/3] database '$DB_NAME' and login '$DB_USER'"

if secret_exists "$DB_SECRET"; then
  DB_PASSWORD="$(secret_get "$DB_SECRET" | json password)"
  echo "      reusing the password already in $DB_SECRET"
else
  DB_PASSWORD="$(genpw)"
  # Saved BEFORE it is used, so a failure below never leaves a login whose
  # password exists nowhere.
  secret_put "$DB_SECRET" "{\"username\":\"$DB_USER\",\"password\":\"$DB_PASSWORD\",\"jdbcUrl\":\"$JDBC_URL\"}"
  echo "      new password saved to $DB_SECRET"
fi

MASTER_JSON="$(secret_get "$MASTER_SECRET_ARN")"
export PGPASSWORD="$(printf '%s' "$MASTER_JSON" | json password)"
MASTER_USER="$(printf '%s' "$MASTER_JSON" | json username)"

# psql variables (:'pw') are quoted by psql itself; the password never sits
# inside a hand-built SQL string.
"$PSQL" "host=$DB_HOST dbname=platform user=$MASTER_USER sslmode=require" \
  -v ON_ERROR_STOP=1 -q -v pw="$DB_PASSWORD" <<SQL
SELECT 'CREATE ROLE ${DB_USER} LOGIN'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') \gexec
ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD :'pw';
-- PostgreSQL 16+: to create a database OWNED BY another role, the creator
-- must be able to SET ROLE to it.
GRANT ${DB_USER} TO CURRENT_USER;
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}') \gexec
SQL
unset PGPASSWORD MASTER_JSON
echo "      ok"

# ---------------------------------------------------------------------------
# 2. Kubernetes Secret the chart reads (persistence.relationalJdbc.secret)
# ---------------------------------------------------------------------------
echo "[2/3] namespace '$NAMESPACE' and secret '$K8S_SECRET'"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NAMESPACE" create secret generic "$K8S_SECRET" \
  --from-literal=username="$DB_USER" \
  --from-literal=password="$DB_PASSWORD" \
  --from-literal=jdbcUrl="$JDBC_URL" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
unset DB_PASSWORD
echo "      ok"

# ---------------------------------------------------------------------------
# 3. Realm bootstrap: creates Polaris's tables and the root principal
# ---------------------------------------------------------------------------
echo "[3/3] realm '$REALM'"

if secret_exists "$ROOT_SECRET" && [ "$(secret_get "$ROOT_SECRET" | json bootstrapped)" = "True" ]; then
  echo "      already bootstrapped ($ROOT_SECRET) -- skipping"
else
  if secret_exists "$ROOT_SECRET"; then
    ROOT_CLIENT_SECRET="$(secret_get "$ROOT_SECRET" | json clientSecret)"
    echo "      retrying with the credentials already in $ROOT_SECRET"
  else
    ROOT_CLIENT_SECRET="$(genpw)"
    # Saved first, marked not-yet-bootstrapped: if the pod below fails, the
    # next run retries with the SAME credentials instead of inventing new
    # ones Polaris has never heard of.
    secret_put "$ROOT_SECRET" "{\"realm\":\"$REALM\",\"clientId\":\"root\",\"clientSecret\":\"$ROOT_CLIENT_SECRET\",\"bootstrapped\":false}"
  fi

  OVERRIDES=$(python3 - "$REALM" "$ROOT_CLIENT_SECRET" "$ADMIN_TOOL_IMAGE" "$K8S_SECRET" <<'PY'
import json, sys
realm, secret, image, k8s = sys.argv[1:5]
env = [{"name": "POLARIS_PERSISTENCE_TYPE", "value": "relational-jdbc"}]
for var, key in [("QUARKUS_DATASOURCE_USERNAME", "username"),
                 ("QUARKUS_DATASOURCE_PASSWORD", "password"),
                 ("QUARKUS_DATASOURCE_JDBC_URL", "jdbcUrl")]:
    env.append({"name": var, "valueFrom": {"secretKeyRef": {"name": k8s, "key": key}}})
print(json.dumps({"spec": {"containers": [{
    "name": "polaris-bootstrap", "image": image, "stdin": True,
    "args": ["bootstrap", "-r", realm, "-c", f"{realm},root,{secret}"],
    "env": env}]}}))
PY
)
  kubectl -n "$NAMESPACE" run polaris-bootstrap --image="$ADMIN_TOOL_IMAGE" \
    --restart=Never --rm -i --overrides="$OVERRIDES"
  unset OVERRIDES

  secret_put "$ROOT_SECRET" "{\"realm\":\"$REALM\",\"clientId\":\"root\",\"clientSecret\":\"$ROOT_CLIENT_SECRET\",\"bootstrapped\":true}"
  unset ROOT_CLIENT_SECRET
  echo "      bootstrapped; root credentials in $ROOT_SECRET"
fi

echo ""
echo "Done. Next: git mv argocd/next/polaris.yaml argocd/apps/ && git commit && git push"

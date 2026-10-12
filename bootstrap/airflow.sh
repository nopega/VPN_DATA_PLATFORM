#!/usr/bin/env bash
#
# bootstrap/airflow.sh -- what Airflow needs before (and right after) Argo CD
# installs it.
#
#   ./airflow.sh          before:  database + login in RDS, and the four Secrets
#                                  the chart reads (namespace airflow)
#   ./airflow.sh admin    after the api-server pod is Running: the UI login
#   ./airflow.sh show     print the admin password
#
# Secrets in namespace airflow (names are what the original values.yaml uses):
#   airflow-metadata        connection   postgresql://airflow:...@<rds>/airflow
#   airflow-fernet-key      fernet-key   encrypts connections/variables in the DB
#   airflow-api-secret-key  api-secret-key   signs UI session cookies
#   airflow-jwt-secret      jwt-secret   signs tokens between Airflow components
#
# Why made here and not by the chart: the chart generates the last three when
# they are missing -- and under Argo CD it would generate NEW ones on every
# render. A new fernet key makes every stored connection undecryptable; a new
# JWT secret fails running tasks mid-flight. Generated once, kept in Secrets
# Manager, reused on every run and every cluster rebuild:
#   vpn-data-platform/airflow-db        {username, password}
#   vpn-data-platform/airflow-internal  {fernetKey, apiSecretKey, jwtSecret}
#   vpn-data-platform/airflow-admin     the UI admin password (plain string)
#
# Needs: aws, kubectl, terraform, python3, openssl, psql (brew install libpq).

set -euo pipefail

REGION="ap-southeast-1"
PROJECT="vpn-data-platform"
NAMESPACE="airflow"
DB_NAME="airflow"
DB_USER="airflow"
DB_SECRET="${PROJECT}/airflow-db"
INTERNAL_SECRET="${PROJECT}/airflow-internal"
ADMIN_SECRET="${PROJECT}/airflow-admin"
MODE="${1:-create}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF06="$REPO_ROOT/terraform/06_data_foundation"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }
need aws; need python3

field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
secret_exists() { aws secretsmanager describe-secret --region "$REGION" --secret-id "$1" >/dev/null 2>&1; }
secret_get() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text; }
secret_create() { aws secretsmanager create-secret --region "$REGION" --name "$1" --secret-string file:///dev/stdin >/dev/null; }
genpw() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

if [ "$MODE" = "show" ]; then
  secret_get "$ADMIN_SECRET"; echo
  exit 0
fi

need kubectl; need openssl
kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl cannot reach the cluster. Is Tailscale connected?" >&2; exit 1; }

# ---------------------------------------------------------------------------
# admin: the UI login, once the api-server is up
# ---------------------------------------------------------------------------
if [ "$MODE" = "admin" ]; then
  POD="$(kubectl -n "$NAMESPACE" get pods -l component=api-server \
    --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "$POD" ] || { echo "ERROR: no Running api-server pod in $NAMESPACE yet." >&2; exit 1; }

  if ! secret_exists "$ADMIN_SECRET"; then
    genpw 24 | tr -d '\n' | secret_create "$ADMIN_SECRET"
    echo "new admin password saved to $ADMIN_SECRET"
  fi
  # Password over stdin into the pod; it never sits on this machine's
  # command line. `users reset-password` makes a re-run converge instead of
  # failing on "user already exists".
  secret_get "$ADMIN_SECRET" | kubectl -n "$NAMESPACE" exec -i "$POD" -c api-server -- bash -c '
    PW="$(cat)"
    if airflow users list -o plain 2>/dev/null | grep -qw admin; then
      airflow users reset-password --username admin --password "$PW" >/dev/null && echo "admin password reset"
    else
      airflow users create --username admin --role Admin --firstname Platform --lastname Admin \
        --email admin@nopega.net --password "$PW" >/dev/null && echo "admin created"
    fi'
  echo "login: https://airflow.nopega.net  admin / \$($0 show)"
  exit 0
fi

need terraform
PSQL="$(command -v psql || true)"
if [ -z "$PSQL" ] && command -v brew >/dev/null 2>&1; then
  PSQL="$(brew --prefix libpq 2>/dev/null)/bin/psql"
fi
[ -x "$PSQL" ] || { echo "ERROR: psql not found. brew install libpq" >&2; exit 1; }

echo "== Airflow bootstrap =============================================="
DB_HOST="$(terraform -chdir="$TF06" output -raw db_address)"
MASTER_SECRET_ARN="$(terraform -chdir="$TF06" output -raw db_master_secret_arn)"
echo "database host: $DB_HOST"

# ---------------------------------------------------------------------------
echo "[1/3] database '$DB_NAME' and login '$DB_USER'"
if secret_exists "$DB_SECRET"; then
  DB_PASSWORD="$(secret_get "$DB_SECRET" | field password)"
  echo "      reusing the password already in $DB_SECRET"
else
  DB_PASSWORD="$(genpw 32)"
  printf '{"username":"%s","password":"%s"}' "$DB_USER" "$DB_PASSWORD" | secret_create "$DB_SECRET"
  echo "      new password saved to $DB_SECRET"
fi

MASTER_JSON="$(secret_get "$MASTER_SECRET_ARN")"
export PGPASSWORD="$(printf '%s' "$MASTER_JSON" | field password)"
MASTER_USER="$(printf '%s' "$MASTER_JSON" | field username)"
"$PSQL" "host=$DB_HOST dbname=platform user=$MASTER_USER sslmode=require" \
  -v ON_ERROR_STOP=1 -q -v pw="$DB_PASSWORD" <<SQL
SELECT 'CREATE ROLE ${DB_USER} LOGIN'
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') \gexec
ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD :'pw';
GRANT ${DB_USER} TO CURRENT_USER;
SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}') \gexec
SQL
unset PGPASSWORD MASTER_JSON
echo "      ok"

# ---------------------------------------------------------------------------
echo "[2/3] internal keys"
if secret_exists "$INTERNAL_SECRET"; then
  echo "      reusing $INTERNAL_SECRET"
else
  # Fernet needs exactly 32 random bytes, url-safe base64.
  python3 -c "
import base64, json, os, secrets
print(json.dumps({
  'fernetKey':    base64.urlsafe_b64encode(os.urandom(32)).decode(),
  'apiSecretKey': secrets.token_urlsafe(48),
  'jwtSecret':    secrets.token_urlsafe(48),
}))" | secret_create "$INTERNAL_SECRET"
  echo "      generated and saved to $INTERNAL_SECRET"
fi

# ---------------------------------------------------------------------------
echo "[3/3] secrets in namespace '$NAMESPACE'"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

DB_JSON="$(secret_get "$DB_SECRET")" IN_JSON="$(secret_get "$INTERNAL_SECRET")" \
HOST="$DB_HOST" DB="$DB_NAME" NS="$NAMESPACE" python3 - <<'PY' | kubectl apply -f - >/dev/null
import base64, json, os
from urllib.parse import quote
db = json.loads(os.environ["DB_JSON"]); i = json.loads(os.environ["IN_JSON"]); ns = os.environ["NS"]
url = (f"postgresql://{quote(db['username'])}:{quote(db['password'], safe='')}"
       f"@{os.environ['HOST']}:5432/{os.environ['DB']}?sslmode=require")
def secret(name, key, value):
    return {"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
            "metadata": {"name": name, "namespace": ns},
            "data": {key: base64.b64encode(value.encode()).decode()}}
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": [
    secret("airflow-metadata",       "connection",     url),
    secret("airflow-fernet-key",     "fernet-key",     i["fernetKey"]),
    secret("airflow-api-secret-key", "api-secret-key", i["apiSecretKey"]),
    secret("airflow-jwt-secret",     "jwt-secret",     i["jwtSecret"]),
]}))
PY
unset DB_PASSWORD
echo "      ok"

cat <<EOF

Done. Next:
  1. Delete the old 'airflow' record in Cloudflare.
  2. In vpn-data-platform-apps: mv next/airflow.yaml apps/ && git add -A && git commit && git push
  3. When the api-server pod is Running: $0 admin
EOF

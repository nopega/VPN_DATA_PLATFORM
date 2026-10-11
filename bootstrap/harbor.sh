#!/usr/bin/env bash
#
# bootstrap/harbor.sh -- everything Harbor needs BEFORE Argo CD installs it.
# Run from the Mac, with Tailscale connected, after terraform/08_registry.
#
#   1. a database and a login of its own inside RDS   (registry / harbor)
#   2. an access key for the registry's IAM user       (S3 image layers)
#   3. Harbor's internal secrets, generated once        (see below)
#   4. all of it as Kubernetes Secrets in namespace harbor
#
# WHY HARBOR'S INTERNAL SECRETS ARE MADE HERE AND NOT BY THE CHART
# ---------------------------------------------------------------
# Left alone, the chart generates them while rendering (randAlphaNum, genCA,
# htpasswd with a random salt) and keeps them stable with Helm's `lookup`.
# Argo CD renders with `helm template`, where `lookup` returns nothing -- so
# every render would produce NEW secrets: Argo CD reports the app OutOfSync
# forever, self-heal rewrites the Secrets, the checksum annotations change,
# and Harbor's pods restart on every sync with new keys. Pinning every one of
# them to a Secret made here makes the rendered output identical every time.
#
# Source of truth is AWS Secrets Manager, so a cluster rebuild reuses the same
# values (and the same encryption key for what Harbor has stored):
#   vpn-data-platform/harbor-db         {username, password}
#   vpn-data-platform/harbor-s3         {accessKeyId, secretAccessKey}
#   vpn-data-platform/harbor-internal   {adminPassword, secretKey, ... tokenCert}
#
#   ./harbor.sh          create (safe to re-run; reuses what exists)
#   ./harbor.sh show     print the admin password
#
# Needs: aws, kubectl, terraform, python3, openssl, htpasswd, and psql
#        (brew install libpq -- found even if not on PATH).

set -euo pipefail

REGION="ap-southeast-1"
PROJECT="vpn-data-platform"
NAMESPACE="harbor"
DB_NAME="registry"
DB_USER="harbor"
DB_SECRET="${PROJECT}/harbor-db"
S3_SECRET="${PROJECT}/harbor-s3"
INTERNAL_SECRET="${PROJECT}/harbor-internal"
REGISTRY_USER="harbor_registry_user"   # chart default; the htpasswd line must use it

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF06="$REPO_ROOT/terraform/06_data_foundation"
TF08="$REPO_ROOT/terraform/08_registry"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. $2" >&2; exit 1; }; }
need aws ""; need python3 ""

field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
secret_exists() { aws secretsmanager describe-secret --region "$REGION" --secret-id "$1" >/dev/null 2>&1; }
secret_get() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text; }
secret_create() {   # name, json on stdin -- never on the command line
  aws secretsmanager create-secret --region "$REGION" --name "$1" \
    --secret-string file:///dev/stdin >/dev/null
}
secret_put() {      # name, json on stdin
  aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" \
    --secret-string file:///dev/stdin >/dev/null
}
genpw() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

# Harbor's token service only reads PKCS#1 keys ("BEGIN RSA PRIVATE KEY");
# a PKCS#8 key ("BEGIN PRIVATE KEY") makes every docker login fail with a 500
# and "unable to get PrivateKey from PEM type: PRIVATE KEY" in harbor-core.
# OpenSSL 3 writes PKCS#8 by default and needs -traditional; macOS's LibreSSL
# has no -traditional and already writes PKCS#1 from `openssl rsa`.
to_pkcs1() {        # key file, converted in place
  head -1 "$1" | grep -q 'BEGIN RSA PRIVATE KEY' && return 0
  openssl rsa -in "$1" -out "$1.rsa" -traditional 2>/dev/null \
    || openssl rsa -in "$1" -out "$1.rsa" 2>/dev/null
  head -1 "$1.rsa" | grep -q 'BEGIN RSA PRIVATE KEY' \
    || { echo "ERROR: could not convert the token key to PKCS#1" >&2; exit 1; }
  mv "$1.rsa" "$1"
}

if [ "${1:-}" = "show" ]; then
  secret_get "$INTERNAL_SECRET" | field adminPassword
  exit 0
fi

need kubectl ""; need terraform ""; need openssl ""
need htpasswd "macOS ships it at /usr/sbin/htpasswd; otherwise: brew install httpd"
PSQL="$(command -v psql || true)"
if [ -z "$PSQL" ] && command -v brew >/dev/null 2>&1; then
  PSQL="$(brew --prefix libpq 2>/dev/null)/bin/psql"
fi
[ -x "$PSQL" ] || { echo "ERROR: psql not found. brew install libpq" >&2; exit 1; }

echo "== Harbor bootstrap ==============================================="

kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl cannot reach the cluster. Is Tailscale connected?" >&2; exit 1; }

DB_HOST="$(terraform -chdir="$TF06" output -raw db_address)"
MASTER_SECRET_ARN="$(terraform -chdir="$TF06" output -raw db_master_secret_arn)"
IAM_USER="$(terraform -chdir="$TF08" output -raw registry_iam_user)"
BUCKET="$(terraform -chdir="$TF08" output -raw registry_bucket)"
echo "database host:   $DB_HOST"
echo "registry bucket: $BUCKET"

# ---------------------------------------------------------------------------
# 1. Database and login
# ---------------------------------------------------------------------------
echo "[1/4] database '$DB_NAME' and login '$DB_USER'"

if secret_exists "$DB_SECRET"; then
  DB_PASSWORD="$(secret_get "$DB_SECRET" | field password)"
  echo "      reusing the password already in $DB_SECRET"
else
  DB_PASSWORD="$(genpw 32)"
  # Saved BEFORE it is used, so a failure below never leaves a login whose
  # password exists nowhere.
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
# 2. S3 access key for the registry
# ---------------------------------------------------------------------------
echo "[2/4] access key for IAM user '$IAM_USER'"

if secret_exists "$S3_SECRET"; then
  echo "      reusing the key already in $S3_SECRET"
else
  EXISTING="$(aws iam list-access-keys --user-name "$IAM_USER" --query 'length(AccessKeyMetadata)' --output text)"
  if [ "$EXISTING" != "0" ]; then
    echo "ERROR: $IAM_USER already has $EXISTING access key(s), but $S3_SECRET does not exist," >&2
    echo "       so the secret half is lost. Delete the old key(s) and re-run:" >&2
    echo "       aws iam list-access-keys --user-name $IAM_USER" >&2
    echo "       aws iam delete-access-key --user-name $IAM_USER --access-key-id <id>" >&2
    exit 1
  fi
  # AWS returns the secret half exactly once. It goes from this response
  # straight into Secrets Manager -- never printed, never in a variable that
  # outlives the pipe.
  aws iam create-access-key --user-name "$IAM_USER" --output json \
    | python3 -c "import json,sys; k=json.load(sys.stdin)['AccessKey']; print(json.dumps({'accessKeyId':k['AccessKeyId'],'secretAccessKey':k['SecretAccessKey']}))" \
    | secret_create "$S3_SECRET"
  echo "      new key saved to $S3_SECRET"
fi

# ---------------------------------------------------------------------------
# 3. Harbor's internal secrets
# ---------------------------------------------------------------------------
echo "[3/4] internal secrets"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if secret_exists "$INTERNAL_SECRET"; then
  echo "      reusing $INTERNAL_SECRET"
  # Repair a token key saved as PKCS#8 by an earlier version of this script.
  # Same key, different encoding: the certificate stays valid.
  secret_get "$INTERNAL_SECRET" > "$WORK/internal.json"
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['tokenKey'], end='')" \
    "$WORK/internal.json" > "$WORK/token.key"
  if ! head -1 "$WORK/token.key" | grep -q 'BEGIN RSA PRIVATE KEY'; then
    to_pkcs1 "$WORK/token.key"
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1])); d['tokenKey'] = open(sys.argv[2]).read()
print(json.dumps(d))" "$WORK/internal.json" "$WORK/token.key" | secret_put "$INTERNAL_SECRET"
    echo "      token key converted to PKCS#1 -- restart harbor-core after this script"
  fi
else

  # Token signing key: Harbor signs registry access tokens with it. Ten years,
  # because the chart's own default (one year) expires silently and every
  # docker login starts failing on the anniversary.
  openssl genrsa -out "$WORK/token.key" 4096 2>/dev/null
  to_pkcs1 "$WORK/token.key"
  openssl req -x509 -new -key "$WORK/token.key" -days 3650 -subj "/CN=harbor-token-ca" \
    -out "$WORK/token.crt" 2>/dev/null

  REGISTRY_PASSWORD="$(genpw 32)"
  # Fixed once: a new bcrypt salt on every run would change the Secret, and
  # the registry only re-reads it on restart.
  printf '%s' "$REGISTRY_PASSWORD" | htpasswd -i -n -B -C 10 "$REGISTRY_USER" \
    | tr -d '\n' > "$WORK/htpasswd"

  ADMIN_PASSWORD="$(genpw 24)" \
  SECRET_KEY="$(genpw 16)" \
  CORE_SECRET="$(genpw 16)" \
  XSRF_KEY="$(genpw 32)" \
  JOBSERVICE_SECRET="$(genpw 16)" \
  REGISTRY_HTTP_SECRET="$(genpw 16)" \
  REGISTRY_PASSWORD="$REGISTRY_PASSWORD" \
  python3 - "$WORK" <<'PY' | secret_create "$INTERNAL_SECRET"
import json, os, sys
w = sys.argv[1]
read = lambda f: open(os.path.join(w, f)).read()
print(json.dumps({
    "adminPassword":      os.environ["ADMIN_PASSWORD"],      # first login only; then it lives in the database
    "secretKey":          os.environ["SECRET_KEY"],          # 16 chars; encrypts stored credentials -- never change it
    "coreSecret":         os.environ["CORE_SECRET"],         # 16 chars
    "xsrfKey":            os.environ["XSRF_KEY"],            # 32 chars
    "jobserviceSecret":   os.environ["JOBSERVICE_SECRET"],   # 16 chars
    "registryHttpSecret": os.environ["REGISTRY_HTTP_SECRET"],# 16 chars
    "registryPassword":   os.environ["REGISTRY_PASSWORD"],
    "registryHtpasswd":   read("htpasswd"),
    "tokenKey":           read("token.key"),
    "tokenCert":          read("token.crt"),
}))
PY
  unset REGISTRY_PASSWORD
  echo "      generated and saved to $INTERNAL_SECRET"
fi

# ---------------------------------------------------------------------------
# 4. Kubernetes Secrets (names are what apps/harbor.yaml points at)
# ---------------------------------------------------------------------------
echo "[4/4] secrets in namespace '$NAMESPACE'"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

DB_JSON="$(secret_get "$DB_SECRET")" \
S3_JSON="$(secret_get "$S3_SECRET")" \
IN_JSON="$(secret_get "$INTERNAL_SECRET")" \
NAMESPACE="$NAMESPACE" \
python3 - <<'PY' | kubectl apply -f - >/dev/null
import base64, json, os
db = json.loads(os.environ["DB_JSON"])
s3 = json.loads(os.environ["S3_JSON"])
i  = json.loads(os.environ["IN_JSON"])
ns = os.environ["NAMESPACE"]

def secret(name, data, type_="Opaque"):
    return {"apiVersion": "v1", "kind": "Secret", "type": type_,
            "metadata": {"name": name, "namespace": ns},
            "data": {k: base64.b64encode(v.encode()).decode() for k, v in data.items()}}

items = [
    secret("harbor-database",             {"password": db["password"]}),
    secret("harbor-registry-s3",          {"REGISTRY_STORAGE_S3_ACCESSKEY": s3["accessKeyId"],
                                           "REGISTRY_STORAGE_S3_SECRETKEY": s3["secretAccessKey"]}),
    secret("harbor-admin-password",       {"HARBOR_ADMIN_PASSWORD": i["adminPassword"]}),
    secret("harbor-secret-key",           {"secretKey": i["secretKey"]}),
    secret("harbor-core-secret",          {"secret": i["coreSecret"]}),
    secret("harbor-xsrf",                 {"CSRF_KEY": i["xsrfKey"]}),
    secret("harbor-jobservice-secret",    {"JOBSERVICE_SECRET": i["jobserviceSecret"]}),
    secret("harbor-registry-http",        {"REGISTRY_HTTP_SECRET": i["registryHttpSecret"]}),
    secret("harbor-registry-credentials", {"REGISTRY_PASSWD": i["registryPassword"],
                                           "REGISTRY_HTPASSWD": i["registryHtpasswd"]}),
    secret("harbor-token-cert",           {"tls.key": i["tokenKey"], "tls.crt": i["tokenCert"]},
           "kubernetes.io/tls"),
]
print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
PY
echo "      ok: $(kubectl -n "$NAMESPACE" get secrets -o name | grep -c 'secret/harbor-') secrets"

cat <<EOF

Done. Next:
  1. Delete the old 'harbor' record in Cloudflare.
  2. In vpn-data-platform-apps: mv next/harbor.yaml apps/ && git add -A && git commit && git push
Login: admin / \$($0 show)
EOF

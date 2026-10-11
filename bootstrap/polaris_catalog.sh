#!/usr/bin/env bash
#
# bootstrap/polaris_catalog.sh -- create the Iceberg catalog inside Polaris.
# Run once Polaris is Running (after bootstrap/polaris.sh and the Argo CD app).
#
#   catalog "data_platform"
#     base location   s3://<warehouse bucket>
#     storage role    vpn-data-platform-polaris-storage (from terraform/06)
#   catalog_admin  <- CATALOG_MANAGE_CONTENT
#   service_admin  <- catalog_admin        (so the root principal can use it)
#
# Same catalog name and grant chain as the original platform, so Spark and
# Trino configuration carries over unchanged.
#
#   ./polaris_catalog.sh          create (idempotent)
#   ./polaris_catalog.sh verify   print catalog, grants and namespaces
#
# Talks to Polaris through `kubectl port-forward` -- the management API is
# never exposed on the load balancer. Needs Tailscale connected.

set -euo pipefail

REGION="ap-southeast-1"
NAMESPACE="polaris"
SERVICE="polaris"
CATALOG="data_platform"
ROOT_SECRET="vpn-data-platform/polaris-root"
LOCAL_PORT="18181"
API="http://localhost:${LOCAL_PORT}"
MODE="${1:-create}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF06="$REPO_ROOT/terraform/06_data_foundation"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }
need aws; need kubectl; need terraform; need curl; need python3

jget() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get('$1','') if isinstance(d,dict) else '')"; }
pretty() { python3 -m json.tool 2>/dev/null || cat; }

# ---------------------------------------------------------------------------
echo "[1/4] inputs"
WAREHOUSE="$(terraform -chdir="$TF06" output -raw warehouse_bucket)"
STORAGE_ROLE="$(terraform -chdir="$TF06" output -raw polaris_storage_role_arn)"
ROOT_JSON="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$ROOT_SECRET" \
  --query SecretString --output text)"
REALM="$(printf '%s' "$ROOT_JSON" | jget realm)"
CLIENT_ID="$(printf '%s' "$ROOT_JSON" | jget clientId)"
CLIENT_SECRET="$(printf '%s' "$ROOT_JSON" | jget clientSecret)"
unset ROOT_JSON
BASE="s3://${WAREHOUSE}"
echo "      realm=$REALM  warehouse=$BASE  role=${STORAGE_ROLE##*/}"

# ---------------------------------------------------------------------------
echo "[2/4] Polaris ready?"
READY="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/name=polaris \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
[ "$READY" = "true" ] || {
  echo "ERROR: Polaris pod not Ready (got '${READY:-no pod}')." >&2
  echo "       kubectl -n $NAMESPACE get pods ; kubectl -n $NAMESPACE logs deploy/polaris --tail=50" >&2
  exit 1; }
echo "      yes"

# ---------------------------------------------------------------------------
echo "[3/4] tunnel and token"
PF_LOG="$(mktemp)"; BODY="$(mktemp)"
kubectl -n "$NAMESPACE" port-forward "svc/$SERVICE" "${LOCAL_PORT}:8181" >"$PF_LOG" 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true; rm -f "$PF_LOG" "$BODY"' EXIT
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/api/catalog/v1/config" || true)"
  [ -n "$code" ] && [ "$code" != "000" ] && break
  kill -0 "$PF_PID" 2>/dev/null || { cat "$PF_LOG" >&2; exit 1; }
  sleep 1
done

CODE="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 -X POST "$API/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: $REALM" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode scope=PRINCIPAL_ROLE:ALL)"
TOKEN="$(jget access_token < "$BODY")"
unset CLIENT_SECRET
[ -n "$TOKEN" ] || { echo "ERROR: no token (HTTP $CODE): $(cat "$BODY")" >&2; exit 1; }
echo "      ok"

api() {   # method path [json]
  if [ $# -ge 3 ]; then
    CODE="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 -X "$1" "$API$2" \
      -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: $REALM" \
      -H 'Content-Type: application/json' -d "$3")"
  else
    CODE="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 -X "$1" "$API$2" \
      -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: $REALM")"
  fi
}
fail() { echo "ERROR: $1 (HTTP $CODE): $(cat "$BODY")" >&2; exit 1; }

if [ "$MODE" = "verify" ]; then
  echo "=== catalog ===";            api GET "/api/management/v1/catalogs/$CATALOG"; pretty < "$BODY"
  echo "=== catalog_admin grants ==="; api GET "/api/management/v1/catalogs/$CATALOG/catalog-roles/catalog_admin/grants"; pretty < "$BODY"
  echo "=== namespaces ===";         api GET "/api/catalog/v1/$CATALOG/namespaces"; echo "HTTP $CODE"; pretty < "$BODY"
  exit 0
fi

# ---------------------------------------------------------------------------
echo "[4/4] catalog '$CATALOG'"

api GET "/api/management/v1/catalogs/$CATALOG"
if [ "$CODE" = "200" ]; then
  echo "      exists -- leaving it"
else
  # No externalId, unlike the original: the storage role trusts exactly one
  # principal (the Polaris service role, in the same account), so there is
  # no third party for an external id to guard against.
  api POST "/api/management/v1/catalogs" "$(python3 - "$CATALOG" "$BASE" "$STORAGE_ROLE" "$REGION" <<'PY'
import json, sys
name, base, role, region = sys.argv[1:5]
print(json.dumps({"catalog": {
  "name": name, "type": "INTERNAL",
  "properties": {"default-base-location": base},
  "storageConfigInfo": {"storageType": "S3", "roleArn": role,
                        "region": region, "allowedLocations": [base]}}}))
PY
)"
  case "$CODE" in 2*) echo "      created" ;; *) fail "create catalog" ;; esac
fi

api GET "/api/management/v1/catalogs/$CATALOG/catalog-roles/catalog_admin/grants"
if grep -q CATALOG_MANAGE_CONTENT "$BODY"; then
  echo "      catalog_admin already has CATALOG_MANAGE_CONTENT"
else
  api PUT "/api/management/v1/catalogs/$CATALOG/catalog-roles/catalog_admin/grants" \
    '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}'
  case "$CODE" in 2*) echo "      granted CATALOG_MANAGE_CONTENT" ;; *) fail "grant" ;; esac
fi

api GET "/api/management/v1/principal-roles/service_admin/catalog-roles/$CATALOG"
if grep -q catalog_admin "$BODY"; then
  echo "      service_admin already holds catalog_admin"
else
  api GET "/api/management/v1/catalogs/$CATALOG/catalog-roles/catalog_admin"
  ROLE_JSON="$(cat "$BODY")"
  api PUT "/api/management/v1/principal-roles/service_admin/catalog-roles/$CATALOG" "{\"catalogRole\":$ROLE_JSON}"
  case "$CODE" in 2*) echo "      assigned catalog_admin to service_admin" ;; *) fail "assign" ;; esac
fi

# The call Spark and Trino make first. 200 = the whole grant chain works.
api GET "/api/catalog/v1/$CATALOG/namespaces"
case "$CODE" in
  2*) echo "      namespaces: HTTP $CODE $(cat "$BODY")" ;;
  *)  fail "list namespaces -- catalog exists but is not usable" ;;
esac

cat <<EOF

Catalog '$CATALOG' ready.
  in-cluster URI : http://$SERVICE.$NAMESPACE.svc.cluster.local:8181/api/catalog
  warehouse      : $BASE
Next: Trino, with the iceberg connector pointed at that URI.
EOF

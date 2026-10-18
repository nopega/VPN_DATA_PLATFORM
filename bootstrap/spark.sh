#!/usr/bin/env bash
#
# bootstrap/spark.sh -- the two credentials a Spark job needs that Argo CD
# cannot create, as Secrets in namespace spark:
#
#   harbor-pull                  pull the job image from Harbor
#                                (robot account robot$ice-berg-platform+spark-pull,
#                                 pull only, this one project)
#   spark-polaris-credentials    POLARIS_CREDENTIAL=<clientId>:<clientSecret>
#                                of Polaris principal "etl"
#
# WHY A PRINCIPAL OF ITS OWN, NOT ROOT
# ------------------------------------
# Polaris vends S3 credentials according to the privileges of whoever asks.
# Ask as root and the answer is "everything" -- the original platform's first
# smoke test did exactly that and quietly switched off its own access control.
# "etl" holds one catalog role with CATALOG_MANAGE_CONTENT on data_platform
# and nothing else (no catalog or principal administration).
#
#   principal etl ─▶ principal role etl ─▶ catalog role etl (data_platform)
#                                           └─ CATALOG_MANAGE_CONTENT
#
# Source of truth in Secrets Manager:
#   vpn-data-platform/harbor-robot-spark-pull   {name, secret}
#   vpn-data-platform/polaris-etl               {clientId, clientSecret}
#
#   ./spark.sh          create (safe to re-run)
#
# Run after: bootstrap/harbor.sh (and the ice-berg-platform project exists),
# bootstrap/polaris_catalog.sh. Needs Tailscale connected.

set -euo pipefail

REGION="ap-southeast-1"
PROJECT="vpn-data-platform"
NAMESPACE="spark"
HARBOR="https://harbor.nopega.net"
HARBOR_HOST="harbor.nopega.net"
HARBOR_PROJECT="ice-berg-platform"
ROBOT="spark-pull"
ROBOT_SECRET="${PROJECT}/harbor-robot-spark-pull"
HARBOR_INTERNAL="${PROJECT}/harbor-internal"
POLARIS_ROOT="${PROJECT}/polaris-root"
POLARIS_ETL="${PROJECT}/polaris-etl"
PRINCIPAL="etl"
CATALOG="data_platform"
LOCAL_PORT="18182"
API="http://localhost:${LOCAL_PORT}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found." >&2; exit 1; }; }
need aws; need kubectl; need curl; need python3

field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
jget() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(d.get('$1','') if isinstance(d,dict) else '')"; }
secret_exists() { aws secretsmanager describe-secret --region "$REGION" --secret-id "$1" >/dev/null 2>&1; }
secret_get() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text; }
secret_create() { aws secretsmanager create-secret --region "$REGION" --name "$1" --secret-string file:///dev/stdin >/dev/null; }
secret_put() { aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" --secret-string file:///dev/stdin >/dev/null; }

WORK="$(mktemp -d)"; chmod 700 "$WORK"
BODY="$WORK/body"
PF_PID=""
trap '[ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "== Spark bootstrap ================================================"

kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl cannot reach the cluster. Is Tailscale connected?" >&2; exit 1; }

echo "[1/4] namespace '$NAMESPACE'"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "      ok"

# ---------------------------------------------------------------------------
# 2. Harbor robot account (pull only) -> Secret harbor-pull
# ---------------------------------------------------------------------------
echo "[2/4] Harbor robot '$ROBOT' in project '$HARBOR_PROJECT'"

# Admin password into a curl config file (mode 600), never on a command line.
printf 'user = "admin:%s"\n' "$(secret_get "$HARBOR_INTERNAL" | field adminPassword)" > "$WORK/harbor.curl"
harbor() {   # method path [json]
  if [ $# -ge 3 ]; then
    CODE="$(curl -s -K "$WORK/harbor.curl" -o "$BODY" -w '%{http_code}' -X "$1" "$HARBOR/api/v2.0$2" \
      -H 'Content-Type: application/json' -d "$3")"
  else
    CODE="$(curl -s -K "$WORK/harbor.curl" -o "$BODY" -w '%{http_code}' -X "$1" "$HARBOR/api/v2.0$2")"
  fi
}

harbor GET "/projects/$HARBOR_PROJECT"
[ "$CODE" = "200" ] || { echo "ERROR: Harbor project '$HARBOR_PROJECT' not found (HTTP $CODE). Create it first." >&2; exit 1; }

if secret_exists "$ROBOT_SECRET"; then
  echo "      reusing $ROBOT_SECRET"
else
  # A robot whose secret is not in Secrets Manager is useless (Harbor shows
  # the secret only once). Remove it and make a fresh one.
  harbor GET "/robots?q=name%3D~${ROBOT}&page_size=100"
  for id in $(python3 -c "import json,sys
for r in json.load(open(sys.argv[1])):
    if r['name'].endswith('+$ROBOT'): print(r['id'])" "$BODY"); do
    harbor DELETE "/robots/$id"
    echo "      removed stale robot id $id"
  done

  harbor POST "/robots" "$(python3 - "$ROBOT" "$HARBOR_PROJECT" <<'PY'
import json, sys
name, project = sys.argv[1:3]
print(json.dumps({
  "name": name, "level": "project", "duration": -1, "disable": False,
  "description": "Kubernetes nodes pull Spark job images (vpn-data-platform)",
  "permissions": [{"kind": "project", "namespace": project,
                   "access": [{"resource": "repository", "action": "pull"}]}]}))
PY
)"
  [ "$CODE" = "201" ] || { echo "ERROR: create robot (HTTP $CODE): $(cat "$BODY")" >&2; exit 1; }
  python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps({'name':r['name'],'secret':r['secret']}))" "$BODY" \
    | secret_create "$ROBOT_SECRET"
  echo "      created; saved to $ROBOT_SECRET"
fi

ROBOT_JSON="$(secret_get "$ROBOT_SECRET")" HOST="$HARBOR_HOST" NS="$NAMESPACE" python3 - <<'PY' | kubectl apply -f - >/dev/null
import base64, json, os
r = json.loads(os.environ["ROBOT_JSON"])
auth = base64.b64encode(f"{r['name']}:{r['secret']}".encode()).decode()
cfg = {"auths": {os.environ["HOST"]: {"username": r["name"], "password": r["secret"], "auth": auth}}}
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockerconfigjson",
  "metadata": {"name": "harbor-pull", "namespace": os.environ["NS"]},
  "data": {".dockerconfigjson": base64.b64encode(json.dumps(cfg).encode()).decode()}}))
PY
echo "      secret $NAMESPACE/harbor-pull ok"

# ---------------------------------------------------------------------------
# 3. Polaris principal "etl"
# ---------------------------------------------------------------------------
echo "[3/4] Polaris principal '$PRINCIPAL'"

kubectl -n polaris port-forward svc/polaris "${LOCAL_PORT}:8181" >"$WORK/pf.log" 2>&1 &
PF_PID=$!
for _ in $(seq 1 20); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/api/catalog/v1/config" || true)"
  [ -n "$code" ] && [ "$code" != "000" ] && break
  kill -0 "$PF_PID" 2>/dev/null || { cat "$WORK/pf.log" >&2; exit 1; }
  sleep 1
done

ROOT_JSON="$(secret_get "$POLARIS_ROOT")"
REALM="$(printf '%s' "$ROOT_JSON" | jget realm)"
CODE="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 -X POST "$API/api/catalog/v1/oauth/tokens" \
  -H "Polaris-Realm: $REALM" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$(printf '%s' "$ROOT_JSON" | jget clientId)" \
  --data-urlencode "client_secret=$(printf '%s' "$ROOT_JSON" | jget clientSecret)" \
  --data-urlencode scope=PRINCIPAL_ROLE:ALL)"
unset ROOT_JSON
TOKEN="$(jget access_token < "$BODY")"
[ -n "$TOKEN" ] || { echo "ERROR: no Polaris token (HTTP $CODE): $(cat "$BODY")" >&2; exit 1; }

polaris() {   # method path [json]
  if [ $# -ge 3 ]; then
    CODE="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 -X "$1" "$API$2" \
      -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: $REALM" \
      -H 'Content-Type: application/json' -d "$3")"
  else
    CODE="$(curl -s -o "$BODY" -w '%{http_code}' --max-time 30 -X "$1" "$API$2" \
      -H "Authorization: Bearer $TOKEN" -H "Polaris-Realm: $REALM")"
  fi
}
ok_or_exists() { case "$CODE" in 2*|409) ;; *) echo "ERROR: $1 (HTTP $CODE): $(cat "$BODY")" >&2; exit 1 ;; esac; }
M="/api/management/v1"

polaris POST "$M/principal-roles" "{\"principalRole\":{\"name\":\"$PRINCIPAL\"}}"; ok_or_exists "principal role"
polaris POST "$M/catalogs/$CATALOG/catalog-roles" "{\"catalogRole\":{\"name\":\"$PRINCIPAL\"}}"; ok_or_exists "catalog role"
# Polaris answers a repeated grant or assignment with HTTP 500 (duplicate
# key), not 409, so each one is checked before it is made.
has() { python3 -c "import json,sys
d=json.load(open(sys.argv[1])); s=json.dumps(d)
sys.exit(0 if sys.argv[2] in s else 1)" "$BODY" "$1"; }

polaris GET "$M/catalogs/$CATALOG/catalog-roles/$PRINCIPAL/grants"
if ! has CATALOG_MANAGE_CONTENT; then
  polaris PUT "$M/catalogs/$CATALOG/catalog-roles/$PRINCIPAL/grants" \
    '{"grant":{"type":"catalog","privilege":"CATALOG_MANAGE_CONTENT"}}'; ok_or_exists "grant"
fi
polaris GET "$M/principal-roles/$PRINCIPAL/catalog-roles/$CATALOG"
if ! has "\"$PRINCIPAL\""; then
  polaris PUT "$M/principal-roles/$PRINCIPAL/catalog-roles/$CATALOG" \
    "{\"catalogRole\":{\"name\":\"$PRINCIPAL\"}}"; ok_or_exists "catalog role -> principal role"
fi

if secret_exists "$POLARIS_ETL"; then
  echo "      reusing $POLARIS_ETL"
else
  polaris GET "$M/principals/$PRINCIPAL"
  if [ "$CODE" = "200" ]; then
    # Exists, but its secret is not saved anywhere: rotate to get a new one.
    polaris POST "$M/principals/$PRINCIPAL/rotate"
    echo "      principal existed without a saved secret -- rotated"
  else
    polaris POST "$M/principals" "{\"principal\":{\"name\":\"$PRINCIPAL\"},\"credentialRotationRequired\":false}"
  fi
  case "$CODE" in 2*) ;; *) echo "ERROR: principal (HTTP $CODE): $(cat "$BODY")" >&2; exit 1 ;; esac
  python3 -c "import json,sys; c=json.load(open(sys.argv[1]))['credentials']; print(json.dumps({'clientId':c['clientId'],'clientSecret':c['clientSecret']}))" "$BODY" \
    | secret_create "$POLARIS_ETL"
  echo "      created; saved to $POLARIS_ETL"
fi
polaris GET "$M/principals/$PRINCIPAL/principal-roles"
if ! has "\"$PRINCIPAL\""; then
  polaris PUT "$M/principals/$PRINCIPAL/principal-roles" "{\"principalRole\":{\"name\":\"$PRINCIPAL\"}}"; ok_or_exists "principal role -> principal"
fi
echo "      grants: $PRINCIPAL -> $PRINCIPAL -> $CATALOG/$PRINCIPAL (CATALOG_MANAGE_CONTENT)"

# Namespaces the pipelines write into (dags/nyc_taxi_medallion). Spark's
# createOrReplace makes tables, not namespaces; a missing one fails the first
# bronze run with NoSuchNamespaceException.
for ns in bronze silver gold bronze.transactional silver.derived gold.aggregate; do
  polaris POST "/api/catalog/v1/$CATALOG/namespaces" \
    "$(python3 -c "import json,sys; print(json.dumps({'namespace': sys.argv[1].split('.')}))" "$ns")"
  ok_or_exists "namespace $ns"
done
echo "      namespaces: bronze.transactional silver.derived gold.aggregate"

# ---------------------------------------------------------------------------
# 4. Secret spark-polaris-credentials
# ---------------------------------------------------------------------------
echo "[4/4] secret '$NAMESPACE/spark-polaris-credentials'"
# Iceberg's REST client wants one string, clientId:clientSecret. Joined here,
# at the point of use; Secrets Manager keeps the two fields separate.
ETL_JSON="$(secret_get "$POLARIS_ETL")" NS="$NAMESPACE" python3 - <<'PY' | kubectl apply -f - >/dev/null
import base64, json, os
c = json.loads(os.environ["ETL_JSON"])
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
  "metadata": {"name": "spark-polaris-credentials", "namespace": os.environ["NS"]},
  "data": {"POLARIS_CREDENTIAL": base64.b64encode(f"{c['clientId']}:{c['clientSecret']}".encode()).decode()}}))
PY
echo "      ok"

cat <<EOF

Done. Next (vpn-data-platform-apps):
  1. images/spark/build.sh            build and push the job image
  2. mv next/spark-operator.yaml apps/ && git add -A && git commit && git push
  3. kubectl apply -f runs/smoke-test.yaml
EOF

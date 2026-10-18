#!/usr/bin/env bash
#
# bootstrap/ci.sh -- credentials for CI, before terraform/11_ci.
#
#   1. GitHub token for the runner listener -> Secret arc-runners/github-runner-auth
#      (you paste it once; it is kept in Secrets Manager after that)
#   2. Harbor robot account "ci-push" (push + pull, project ice-berg-platform)
#   3. its name and secret as GitHub repository secrets HARBOR_USERNAME /
#      HARBOR_PASSWORD on nopega/vpn-data-platform-apps (with the `gh` CLI)
#
# Source of truth in Secrets Manager:
#   vpn-data-platform/github-runner-token       the fine-grained token
#   vpn-data-platform/harbor-robot-ci-push      {name, secret}
#
# THE GITHUB TOKEN (make it once, in the browser)
# -----------------------------------------------
#   github.com → Settings → Developer settings → Personal access tokens →
#   Fine-grained tokens → Generate new token
#     Repository access : Only select repositories → vpn-data-platform-apps
#     Permissions       : Administration → Read and write
#                         (Metadata → Read-only is added automatically)
#     Expiration        : your choice -- when it expires, runners stop
#                         picking up jobs; re-run `./ci.sh token`
#
#   ./ci.sh          everything (asks for the token the first time)
#   ./ci.sh token    replace the GitHub token
#
# Needs: aws, kubectl, curl, python3, gh (brew install gh; gh auth login).

set -euo pipefail

REGION="ap-southeast-1"
PROJECT="vpn-data-platform"
NAMESPACE="arc-runners"
REPO="nopega/vpn-data-platform-apps"
TOKEN_SECRET="${PROJECT}/github-runner-token"
HARBOR="https://harbor.nopega.net"
HARBOR_PROJECT="ice-berg-platform"
ROBOT="ci-push"
ROBOT_SECRET="${PROJECT}/harbor-robot-ci-push"
HARBOR_INTERNAL="${PROJECT}/harbor-internal"
MODE="${1:-create}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found. $2" >&2; exit 1; }; }
need aws ""; need kubectl ""; need curl ""; need python3 ""
need gh "brew install gh && gh auth login"

field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
secret_exists() { aws secretsmanager describe-secret --region "$REGION" --secret-id "$1" >/dev/null 2>&1; }
secret_get() { aws secretsmanager get-secret-value --region "$REGION" --secret-id "$1" --query SecretString --output text; }
secret_create() { aws secretsmanager create-secret --region "$REGION" --name "$1" --secret-string file:///dev/stdin >/dev/null; }
secret_put() { aws secretsmanager put-secret-value --region "$REGION" --secret-id "$1" --secret-string file:///dev/stdin >/dev/null; }

WORK="$(mktemp -d)"; chmod 700 "$WORK"; BODY="$WORK/body"
trap 'rm -rf "$WORK"' EXIT

kubectl get nodes >/dev/null 2>&1 \
  || { echo "ERROR: kubectl cannot reach the cluster. Is Tailscale connected (and the platform scaled up)?" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh is not logged in: gh auth login" >&2; exit 1; }

echo "== CI bootstrap ==================================================="

# ---------------------------------------------------------------------------
echo "[1/3] GitHub token for the runners"
if [ "$MODE" = "token" ] || ! secret_exists "$TOKEN_SECRET"; then
  printf "      paste the fine-grained token (input hidden): "
  read -rs GH_TOKEN; echo
  [ -n "$GH_TOKEN" ] || { echo "ERROR: empty token" >&2; exit 1; }
  # Checked against the repository before it is stored.
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runners")"
  [ "$code" = "200" ] || { echo "ERROR: token cannot read $REPO's runners (HTTP $code). Needs Administration: Read and write." >&2; exit 1; }
  if secret_exists "$TOKEN_SECRET"; then printf '%s' "$GH_TOKEN" | secret_put "$TOKEN_SECRET"
  else printf '%s' "$GH_TOKEN" | secret_create "$TOKEN_SECRET"; fi
  unset GH_TOKEN
  echo "      saved to $TOKEN_SECRET"
else
  echo "      reusing $TOKEN_SECRET"
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
TOK="$(secret_get "$TOKEN_SECRET")" NS="$NAMESPACE" python3 - <<'PY' | kubectl apply -f - >/dev/null
import base64, json, os
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "type": "Opaque",
  "metadata": {"name": "github-runner-auth", "namespace": os.environ["NS"]},
  "data": {"github_token": base64.b64encode(os.environ["TOK"].encode()).decode()}}))
PY
echo "      secret $NAMESPACE/github-runner-auth ok"
[ "$MODE" = "token" ] && { echo "Restart the listener to pick it up:"; echo "  kubectl -n arc-systems delete pod -l app.kubernetes.io/component=runner-scale-set-listener"; exit 0; }

# ---------------------------------------------------------------------------
echo "[2/3] Harbor robot '$ROBOT' (push + pull, project $HARBOR_PROJECT)"
printf 'user = "admin:%s"\n' "$(secret_get "$HARBOR_INTERNAL" | field adminPassword)" > "$WORK/harbor.curl"
harbor() {
  if [ $# -ge 3 ]; then
    CODE="$(curl -s -K "$WORK/harbor.curl" -o "$BODY" -w '%{http_code}' -X "$1" "$HARBOR/api/v2.0$2" -H 'Content-Type: application/json' -d "$3")"
  else
    CODE="$(curl -s -K "$WORK/harbor.curl" -o "$BODY" -w '%{http_code}' -X "$1" "$HARBOR/api/v2.0$2")"
  fi
}
if secret_exists "$ROBOT_SECRET"; then
  echo "      reusing $ROBOT_SECRET"
else
  harbor GET "/robots?q=name%3D~${ROBOT}&page_size=100"
  for id in $(python3 -c "import json,sys
for r in json.load(open(sys.argv[1])):
    if r['name'].endswith('+$ROBOT'): print(r['id'])" "$BODY"); do
    harbor DELETE "/robots/$id"; echo "      removed stale robot id $id"
  done
  harbor POST "/robots" "$(python3 - "$ROBOT" "$HARBOR_PROJECT" <<'PY'
import json, sys
name, project = sys.argv[1:3]
print(json.dumps({
  "name": name, "level": "project", "duration": -1, "disable": False,
  "description": "GitHub Actions (vpn-data-platform-apps) pushes images",
  "permissions": [{"kind": "project", "namespace": project, "access": [
      {"resource": "repository", "action": "pull"},
      {"resource": "repository", "action": "push"}]}]}))
PY
)"
  [ "$CODE" = "201" ] || { echo "ERROR: create robot (HTTP $CODE): $(cat "$BODY")" >&2; exit 1; }
  python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps({'name':r['name'],'secret':r['secret']}))" "$BODY" \
    | secret_create "$ROBOT_SECRET"
  echo "      created; saved to $ROBOT_SECRET"
fi

# ---------------------------------------------------------------------------
echo "[3/3] repository secrets on $REPO"
# Straight from Secrets Manager into gh over stdin: never on a command line.
secret_get "$ROBOT_SECRET" | field name   | tr -d '\n' | gh secret set HARBOR_USERNAME --repo "$REPO"
secret_get "$ROBOT_SECRET" | field secret | tr -d '\n' | gh secret set HARBOR_PASSWORD --repo "$REPO"
echo "      HARBOR_USERNAME, HARBOR_PASSWORD set"

cat <<EOF

Done. Next:
  1. terraform/11_ci: terraform init && terraform apply
  2. In vpn-data-platform-apps: push .github/workflows/spark-image.yml
  3. Release an image: git tag spark-v0.2.0 && git push origin spark-v0.2.0
EOF

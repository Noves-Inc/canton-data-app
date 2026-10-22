#!/usr/bin/env bash
set -euo pipefail

# Rendering only: no Docker daemon, Kubernetes cluster, or live application is used.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$root/chart/noves-canton-data-app"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export KUBECONFIG="$scratch/empty-kubeconfig"
touch "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

assert_flag() {
  python3 -c '
import json, sys, yaml
kind, expected = sys.argv[1:]
if kind == "compose":
    actual = str(json.load(sys.stdin)["services"]["backend"]["environment"].get("PQS_SOURCE_ENABLED")).lower()
else:
    docs = list(yaml.safe_load_all(sys.stdin))
    backend = next(d for d in docs if d and d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-backend"))
    container = next(c for c in backend["spec"]["template"]["spec"]["containers"] if c["name"] == "backend")
    entries = [e for e in container["env"] if e["name"] == "PQS_SOURCE_ENABLED"]
    assert len(entries) == 1, "expected exactly one PQS_SOURCE_ENABLED entry"
    actual = entries[0]["value"]
assert actual == expected, f"{kind}: expected {expected}, received {actual}"
' "$1" "$2"
}

compose() {
  DATABASE_PASSWORD=test-render-only APP_URL=https://data.example.com \
    docker compose --env-file /dev/null -f "$root/docker-compose/compose.yaml" \
      config --no-env-resolution --format json
}

(unset PQS_SOURCE_ENABLED; compose) | assert_flag compose false
PQS_SOURCE_ENABLED=false compose | assert_flag compose false
PQS_SOURCE_ENABLED=true compose | assert_flag compose true

render() {
  helm template pqs-flag "$chart" --set oidc.provider=auth0 --set oidc.appUrl=https://data.example.com \
    --set oidc.auth0.domain=tenant.auth0.com --set oidc.auth0.clientId=test-render-only \
    --set oidc.auth0.audience=https://canton.network.global "$@"
}

render | assert_flag helm false
render --set backend.pqsSourceEnabled=false | assert_flag helm false
render --set backend.pqsSourceEnabled=true | assert_flag helm true
# Old saved values need not contain a flag introduced by a newer chart.
render --set backend.pqsSourceEnabled=null | assert_flag helm false
if render --set-string backend.pqsSourceEnabled=true >/dev/null 2>&1; then
  echo 'FAIL: Helm accepted a string instead of a boolean' >&2
  exit 1
fi
if render --set 'backend.extraEnv[0].name=PQS_SOURCE_ENABLED' \
    --set-string 'backend.extraEnv[0].value=true' >/dev/null 2>&1; then
  echo 'FAIL: Helm accepted a duplicate PQS_SOURCE_ENABLED via extraEnv' >&2
  exit 1
fi

echo 'PQS source flag Compose/Helm contracts passed'

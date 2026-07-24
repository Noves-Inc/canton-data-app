#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="$repo_root/chart/noves-canton-data-app"
fixtures="$repo_root/tests/fixtures"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'helm-chart test failed: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fiq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

helm lint "$chart" --values "$fixtures/enterprise-values.yaml"
helm lint "$chart" --values "$fixtures/setup-istio-values.yaml"
helm lint "$chart" --values "$chart/examples/enterprise-values.yaml"

helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/enterprise-values.yaml" >"$scratch/enterprise.yaml"
helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/setup-istio-values.yaml" >"$scratch/setup.yaml"
helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/ingress-values.yaml" >"$scratch/ingress.yaml"
helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/migration-values.yaml" >"$scratch/migration.yaml"
helm template cda "$chart" \
  --namespace validator \
  --set database.persistence.existingClaim=cda-encrypted-data \
  --values "$fixtures/enterprise-values.yaml" >"$scratch/existing-database-claim.yaml"

assert_contains "$chart/Chart.yaml" 'name: noves-canton-data-app'
assert_contains "$chart/Chart.yaml" 'version: 4.0.0'
assert_contains "$chart/values.yaml" 'repository: ghcr.io/noves-inc/noves-canton-backend-v4'
assert_contains "$chart/values.yaml" 'repository: ghcr.io/noves-inc/noves-canton-frontend-v4'
assert_contains "$chart/values.yaml" 'repository: ghcr.io/noves-inc/noves-canton-database-v4'
assert_contains "$chart/values.yaml" 'tag: "4.0.0"'
assert_contains "$chart/values.yaml" 'passwordKey: postgres-password'
assert_contains "$chart/values.schema.json" '"const": 1'
assert_not_contains "$chart/values.yaml" 'tag: latest'
assert_not_contains "$chart/values.yaml" 'externalDatabase'
app_version="$(sed -n 's/^appVersion: "\(.*\)"/\1/p' "$chart/Chart.yaml")"
chart_version="$(sed -n 's/^version: //p' "$chart/Chart.yaml")"
[[ "$app_version" == "$chart_version" ]] ||
  fail 'chart version and appVersion differ.'
[[ "$(grep -c "tag: \"$app_version\"" "$chart/values.yaml")" == 3 ]] ||
  fail 'all default image tags must match appVersion.'

assert_contains "$scratch/enterprise.yaml" 'participant:5001'
assert_contains "$scratch/enterprise.yaml" 'http://validator-app:5003'
assert_contains "$scratch/enterprise.yaml" 'name: SCAN_PROXY_URL'
assert_contains "$scratch/enterprise.yaml" 'mountPath: /exports'
assert_contains "$scratch/enterprise.yaml" 'type: Recreate'
assert_contains "$scratch/enterprise.yaml" 'type: RuntimeDefault'
assert_contains "$scratch/enterprise.yaml" 'allowPrivilegeEscalation: false'
assert_contains "$scratch/enterprise.yaml" 'name: cda-capture-auth'
assert_contains "$scratch/enterprise.yaml" 'name: cda-database'
assert_contains "$chart/values.yaml" 'ledgerApiUserKey: ledger-api-user'
assert_contains "$scratch/enterprise.yaml" 'key: token-endpoint'
assert_contains "$scratch/enterprise.yaml" 'key: client-id'
assert_contains "$scratch/enterprise.yaml" 'key: client-secret'
assert_contains "$scratch/enterprise.yaml" 'name: M2M_INDEXER_ENABLED'
[[ "$(grep -c 'name: NOVES_GATEWAY_AUTH_TOKEN' "$scratch/enterprise.yaml")" == 2 ]] ||
  fail 'gateway credential must be injected into backend and frontend'
[[ "$(grep -c 'name: cda-noves-gateway' "$scratch/enterprise.yaml")" == 2 ]] ||
  fail 'backend and frontend must use the configured gateway Secret'
[[ "$(grep -c 'key: gateway-token' "$scratch/enterprise.yaml")" == 2 ]] ||
  fail 'backend and frontend must use the configured gateway Secret key'
assert_contains "$scratch/enterprise.yaml" 'helm.sh/resource-policy: keep'
assert_contains "$scratch/enterprise.yaml" 'kind: VirtualService'
assert_contains "$scratch/enterprise.yaml" 'cluster-ingress/cn-http-gateway'
assert_not_contains "$scratch/enterprise.yaml" 'kind: Role'
assert_not_contains "$scratch/enterprise.yaml" 'CDA_SETUP_WIZARD_ENABLED'

assert_not_contains "$scratch/setup.yaml" 'kind: VirtualService'
assert_not_contains "$scratch/setup.yaml" 'kind: Ingress'
assert_contains "$scratch/setup.yaml" 'name: cda-setup-results'
assert_contains "$scratch/setup.yaml" 'resourceNames:'
assert_contains "$scratch/setup.yaml" '- cda-setup-results'
assert_contains "$scratch/setup.yaml" '- cda-capture-auth'
assert_contains "$scratch/setup.yaml" 'verbs:'
assert_contains "$scratch/setup.yaml" '- get'
assert_contains "$scratch/setup.yaml" '- update'
assert_contains "$scratch/setup.yaml" '- patch'
assert_not_contains "$scratch/setup.yaml" '- list'
assert_not_contains "$scratch/setup.yaml" '- deployments'
assert_not_contains "$scratch/setup.yaml" '/var/run/docker.sock'
assert_contains "$scratch/setup.yaml" 'port: 8080'
assert_contains "$chart/templates/setup-wizard.yaml" 'lookup "v1" "ConfigMap"'

assert_contains "$scratch/ingress.yaml" 'kind: Ingress'
assert_not_contains "$scratch/ingress.yaml" 'kind: VirtualService'
assert_contains "$scratch/migration.yaml" 'claimName: cda-v3-data'
assert_contains "$scratch/existing-database-claim.yaml" 'claimName: cda-encrypted-data'
assert_contains "$scratch/migration.yaml" 'CDA_SETUP_WIZARD_ENABLED'
assert_contains "$scratch/migration.yaml" 'value: "false"'
assert_not_contains "$scratch/migration.yaml" 'kind: Job'

if helm template cda "$chart" --namespace validator \
  --values "$fixtures/invalid-routing-values.yaml" >"$scratch/invalid.out" 2>&1; then
  fail 'chart accepted both Istio and Ingress routing'
fi
assert_contains "$scratch/invalid.out" 'mutually exclusive'

if helm template cda "$chart" --namespace validator \
  --values "$fixtures/invalid-migration-values.yaml" >"$scratch/invalid-migration.out" 2>&1; then
  fail 'chart accepted an unconfirmed v3 migration'
fi
assert_contains "$scratch/invalid-migration.out" 'Data App v3.16.1'

if helm template cda "$chart" --namespace validator \
  --set backend.image.tag=5.0.0 \
  --values "$fixtures/enterprise-values.yaml" >"$scratch/invalid-major.out" 2>&1; then
  fail 'v4 chart accepted a v5 backend image'
fi
assert_contains "$scratch/invalid-major.out" 'backend.image.tag'

replica_chart="$scratch/chart-without-schema"
cp -R "$chart" "$replica_chart"
rm "$replica_chart/values.schema.json"
if helm template cda "$replica_chart" --namespace validator \
  --set backend.replicaCount=2 \
  --values "$fixtures/enterprise-values.yaml" >"$scratch/invalid-replicas.out" 2>&1; then
  fail 'chart accepted more than one backend replica'
fi
assert_contains "$scratch/invalid-replicas.out" 'backend.replicaCount must be 1'

printf 'helm chart tests passed\n'

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
helm lint "$chart" --values "$fixtures/istio-values.yaml"
helm lint "$chart" --values "$fixtures/setup-istio-values.yaml"
helm lint "$chart" --values "$fixtures/s3-values.yaml"
helm lint "$chart" --values "$chart/examples/enterprise-values.yaml"
if helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set-string backend.publicApiUrl=http://api.example.test >/dev/null 2>&1; then
  fail 'backend.publicApiUrl accepted remote plain HTTP.'
fi
if helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set-string backend.publicApiUrl=http://127.999.999.999:8099 >/dev/null 2>&1; then
  fail 'backend.publicApiUrl accepted an invalid loopback-looking host.'
fi
for invalid_url in \
  'http://127.0.0.1:99999' \
  'https://api.example.test:99999'; do
  if helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
    --set-string "backend.publicApiUrl=$invalid_url" >/dev/null 2>&1; then
    fail "backend.publicApiUrl accepted an out-of-range port: $invalid_url"
  fi
done
helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set-string backend.publicApiUrl=https://api.example.test >/dev/null
helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set-string backend.publicApiUrl=http://127.0.0.1:8099 >/dev/null
helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set-string backend.publicApiUrl=HTTPS://api.example.test:8443/base >/dev/null
helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set-string backend.publicApiUrl=http://LOCALHOST:8099 >/dev/null
if helm lint "$chart" --values "$fixtures/enterprise-values.yaml" \
  --set backend.performance.readModel.backgroundIndexingDutyPercent=50 \
  --set backend.performance.readModel.partyEventsIndexingDelayMs=1 >/dev/null 2>&1; then
  fail 'constrained background duty accepted the deprecated Party Events delay.'
fi

helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/enterprise-values.yaml" >"$scratch/enterprise.yaml"
helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/istio-values.yaml" >"$scratch/istio.yaml"
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
  --values "$fixtures/s3-values.yaml" >"$scratch/s3.yaml"
helm template cda "$chart" \
  --namespace validator \
  --values "$fixtures/enterprise-values.yaml" \
  --values "$fixtures/existing-accounting-secret-values.yaml" >"$scratch/existing-accounting-secret.yaml"
helm template cda "$chart" \
  --namespace validator \
  --set database.persistence.existingClaim=cda-encrypted-data \
  --values "$fixtures/enterprise-values.yaml" >"$scratch/existing-database-claim.yaml"

assert_contains "$chart/Chart.yaml" 'name: noves-canton-data-app'
assert_contains "$chart/Chart.yaml" 'version: 4.0.0'
assert_contains "$chart/values.yaml" 'repository: noves.azurecr.io/cda-backend'
assert_contains "$chart/values.yaml" 'repository: noves.azurecr.io/cda-frontend'
assert_contains "$chart/values.yaml" 'tag: "prod-19b8de69-1785353655"'
assert_contains "$chart/values.yaml" 'tag: "prod-df73e5ab-1785364651"'
assert_contains "$chart/values.yaml" 'tag: "candidate-30160846627-1"'
assert_contains "$chart/values.yaml" 'digest: "sha256:1482f1bbe6ca9039ebe4bdcdf7442d34acf9389b2799215b95e10ee8d01ba49b"'
assert_contains "$chart/values.yaml" 'passwordKey: postgres-password'
assert_contains "$chart/values.yaml" 'publicApiUrl: https://api.canton.noves.fi'
assert_contains "$chart/values.schema.json" '"const": 1'
assert_contains "$chart/values.schema.json" '"publicApiUrl": { "type": "string", "format": "uri", "pattern":'
assert_not_contains "$chart/values.yaml" 'tag: latest'
assert_not_contains "$chart/values.yaml" 'externalDatabase'
app_version="$(sed -n 's/^appVersion: "\(.*\)"/\1/p' "$chart/Chart.yaml")"
chart_version="$(sed -n 's/^version: //p' "$chart/Chart.yaml")"
[[ "$app_version" == "$chart_version" ]] ||
  fail 'chart version and appVersion differ.'
assert_contains "$scratch/enterprise.yaml" 'participant:5001'
assert_contains "$scratch/enterprise.yaml" 'http://validator-app:5003'
assert_contains "$scratch/enterprise.yaml" 'name: SCAN_PROXY_URL'
assert_contains "$scratch/enterprise.yaml" 'name: NOVES_PUBLIC_API_URL'
assert_contains "$scratch/enterprise.yaml" 'value: "https://api.canton.noves.fi"'
assert_not_contains "$scratch/enterprise.yaml" 'CDA_PUBLIC_API_URL'
[[ "$(grep -c 'mountPath: /exports' "$scratch/enterprise.yaml")" == 1 ]] ||
  fail 'only the backend may mount the exports PVC'
assert_not_contains "$scratch/enterprise.yaml" 'mountPath: /app/exports'
assert_contains "$scratch/enterprise.yaml" 'type: Recreate'
assert_contains "$scratch/enterprise.yaml" 'type: RuntimeDefault'
assert_contains "$scratch/enterprise.yaml" 'fsGroup: 1654'
assert_contains "$scratch/enterprise.yaml" 'fsGroupChangePolicy: OnRootMismatch'
assert_contains "$scratch/enterprise.yaml" 'allowPrivilegeEscalation: false'
assert_contains "$scratch/enterprise.yaml" 'runAsUser: 1654'
assert_contains "$scratch/enterprise.yaml" 'runAsUser: 70'
assert_contains "$scratch/enterprise.yaml" 'runAsGroup: 70'
assert_contains "$scratch/enterprise.yaml" 'fsGroup: 70'
assert_contains "$scratch/enterprise.yaml" 'name: ACCOUNTING_TOKEN_ENCRYPTION_KEY'
assert_contains "$scratch/enterprise.yaml" 'name: cda-accounting-token-encryption'
assert_contains "$scratch/enterprise.yaml" 'key: accounting-token-encryption-key'
assert_contains "$scratch/enterprise.yaml" 'name: cda-capture-auth'
assert_contains "$scratch/enterprise.yaml" 'name: cda-database'
assert_contains "$chart/values.yaml" 'ledgerApiUserKey: ledger-api-user'
assert_contains "$scratch/enterprise.yaml" 'key: token-endpoint'
assert_contains "$scratch/enterprise.yaml" 'key: client-id'
assert_contains "$scratch/enterprise.yaml" 'key: client-secret'
assert_contains "$scratch/enterprise.yaml" 'name: M2M_INDEXER_ENABLED'
assert_contains "$scratch/enterprise.yaml" 'name: DATABASE_MAX_PARALLEL_WORKERS_PER_GATHER'
assert_contains "$scratch/enterprise.yaml" 'name: DATABASE_SYNCHRONOUS_COMMIT'
assert_contains "$scratch/enterprise.yaml" 'name: DATABASE_MAX_WAL_SIZE'
assert_contains "$scratch/enterprise.yaml" 'name: INDEX_DB_WRITE_BATCH_SIZE'
assert_contains "$scratch/enterprise.yaml" 'name: READ_MODEL_TOTAL_CAPACITY'
assert_contains "$scratch/enterprise.yaml" 'name: BACKGROUND_INDEXING_DUTY_PERCENT'
assert_contains "$scratch/enterprise.yaml" 'name: PARTY_EVENTS_INDEXING_DELAY_MS'
assert_contains "$scratch/enterprise.yaml" 'name: READ_MODEL_BOOTSTRAP_BATCH_SIZE'
assert_contains "$scratch/enterprise.yaml" 'name: STREAM_POLL_INTERVAL_MS'
assert_contains "$scratch/enterprise.yaml" 'name: STREAM_PAGE_SIZE'
assert_contains "$scratch/enterprise.yaml" 'name: STREAM_RETRY_DELAY_MS'
assert_contains "$scratch/enterprise.yaml" 'name: STREAM_WEBSOCKET_BUFFER_LIMIT'
assert_contains "$scratch/enterprise.yaml" 'name: STREAM_DATABASE_TIMEOUT_SECONDS'
assert_contains "$scratch/enterprise.yaml" 'name: STREAM_DEDUPLICATION_WINDOW_RECORDS'
assert_contains "$scratch/enterprise.yaml" 'name: STREAM_DELIVERY_RECENCY_MINUTES'
assert_contains "$scratch/enterprise.yaml" 'name: ALLOW_PRIVATE_WEBHOOK_TARGETS'
assert_contains "$scratch/enterprise.yaml" 'value: "4294967296"'
assert_contains "$scratch/enterprise.yaml" 'value: "1000000"'
assert_not_contains "$scratch/enterprise.yaml" 'value: "4.294967296e+09"'
assert_not_contains "$scratch/enterprise.yaml" 'value: "1e+06"'
assert_not_contains "$scratch/enterprise.yaml" 'CANTON_STREAM_URL'
assert_contains "$chart/values.schema.json" '"maxParallelWorkersPerGather"'
assert_contains "$chart/values.schema.json" '"synchronousCommit"'
assert_contains "$chart/values.schema.json" '"maxWalSize"'
assert_contains "$chart/values.schema.json" '"writeBatchSize"'
assert_contains "$chart/values.schema.json" '"partyEventsIndexingDelayMs"'
assert_contains "$chart/values.schema.json" '"pollIntervalMs"'
assert_contains "$chart/values.schema.json" '"allowPrivateWebhookTargets"'
[[ "$(grep -c 'name: NOVES_GATEWAY_AUTH_TOKEN' "$scratch/enterprise.yaml")" == 2 ]] ||
  fail 'gateway credential must be injected into backend and frontend'
[[ "$(grep -c 'name: cda-noves-gateway' "$scratch/enterprise.yaml")" == 2 ]] ||
  fail 'backend and frontend must use the configured gateway Secret'
[[ "$(grep -c 'key: gateway-token' "$scratch/enterprise.yaml")" == 2 ]] ||
  fail 'backend and frontend must use the configured gateway Secret key'
assert_contains "$scratch/enterprise.yaml" 'helm.sh/resource-policy: keep'
assert_contains "$scratch/enterprise.yaml" 'kind: Ingress'
assert_contains "$scratch/enterprise.yaml" 'ingressClassName: "nginx"'
assert_contains "$scratch/enterprise.yaml" 'secretName: data-example-com-tls'
assert_not_contains "$scratch/enterprise.yaml" 'kind: VirtualService'
assert_contains "$scratch/istio.yaml" 'kind: VirtualService'
assert_contains "$scratch/istio.yaml" 'cluster-ingress/cn-http-gateway'
assert_not_contains "$scratch/istio.yaml" 'kind: Ingress'
assert_not_contains "$scratch/enterprise.yaml" 'kind: Role'
assert_not_contains "$scratch/enterprise.yaml" 'SETUP_ENABLED'
assert_contains "$scratch/enterprise.yaml" 'kind: NetworkPolicy'
assert_contains "$scratch/enterprise.yaml" 'port: 5432'

assert_not_contains "$scratch/existing-accounting-secret.yaml" 'name: cda-accounting-token-encryption'
assert_contains "$scratch/existing-accounting-secret.yaml" 'name: cda-accounting-key'
assert_contains "$scratch/existing-accounting-secret.yaml" 'key: token-key'

assert_contains "$scratch/s3.yaml" 'name: EXPORTS_S3_BUCKET'
assert_contains "$scratch/s3.yaml" 'value: "cda-exports"'
assert_contains "$scratch/s3.yaml" 'name: EXPORTS_S3_ACCESS_KEY_ID'
assert_contains "$scratch/s3.yaml" 'name: EXPORTS_S3_SECRET_ACCESS_KEY'
assert_contains "$scratch/s3.yaml" 'name: BACKUP_S3_BUCKET'
assert_contains "$scratch/s3.yaml" 'value: "cda-backups"'
assert_not_contains "$scratch/s3.yaml" 'mountPath: /exports'
assert_not_contains "$scratch/s3.yaml" 'name: cda-exports'

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
assert_contains "$scratch/setup.yaml" 'kind: NetworkPolicy'
assert_contains "$scratch/setup.yaml" 'policyTypes:'
assert_contains "$scratch/setup.yaml" '- Ingress'
if grep -Eq '^kind: Service$' "$chart/templates/setup-wizard.yaml"; then
  fail 'setup wizard template still exposes a Kubernetes Service'
fi
assert_contains "$scratch/setup.yaml" 'name: SETUP_SESSION_TOKEN'
assert_contains "$scratch/setup.yaml" 'path: /health'
assert_contains "$scratch/setup.yaml" 'command:'
assert_contains "$scratch/setup.yaml" '- node'
assert_contains "$scratch/setup.yaml" 'args:'
assert_contains "$scratch/setup.yaml" '- runtime/setup.mjs'
assert_not_contains "$scratch/setup.yaml" 'start:setup'
assert_contains "$chart/templates/setup-wizard.yaml" 'lookup "v1" "ConfigMap"'
assert_contains "$chart/templates/NOTES.txt" 'port-forward deployment/'
assert_contains "$chart/templates/NOTES.txt" ':3000'
assert_not_contains "$chart/templates/NOTES.txt" '.Values.routing.enabled'

assert_contains "$scratch/ingress.yaml" 'kind: Ingress'
assert_not_contains "$scratch/ingress.yaml" 'kind: VirtualService'
assert_contains "$scratch/migration.yaml" 'claimName: cda-v3-data'
assert_contains "$scratch/existing-database-claim.yaml" 'claimName: cda-encrypted-data'
assert_contains "$scratch/migration.yaml" 'SETUP_ENABLED'
assert_contains "$scratch/migration.yaml" 'value: "false"'
assert_contains "$scratch/migration.yaml" 'name: DATABASE_EXPECTED_SOURCE'
assert_contains "$scratch/migration.yaml" 'value: "v3"'
assert_not_contains "$scratch/migration.yaml" 'kind: Job'

if helm template cda "$chart" --namespace validator \
  --values "$fixtures/invalid-routing-values.yaml" >"$scratch/invalid.out" 2>&1; then
  fail 'chart accepted both Istio and Ingress routing'
fi
assert_contains "$scratch/invalid.out" 'routing.ingress.className'

if helm template cda "$chart" --namespace validator \
  --values "$fixtures/enterprise-values.yaml" \
  --set routing.provider=traefik >"$scratch/invalid-provider.out" 2>&1; then
  fail 'chart accepted an unknown routing provider'
fi
assert_contains "$scratch/invalid-provider.out" 'routing.provider'

if helm template cda "$chart" --namespace validator \
  --values "$fixtures/invalid-migration-values.yaml" >"$scratch/invalid-migration.out" 2>&1; then
  fail 'chart accepted an unconfirmed v3 migration'
fi
assert_contains "$scratch/invalid-migration.out" 'cannot be enabled together'

if helm template cda "$chart" --namespace validator \
  --set backend.image.digest=sha256:not-a-digest \
  --values "$fixtures/enterprise-values.yaml" >"$scratch/invalid-major.out" 2>&1; then
  fail 'chart accepted a malformed backend image digest'
fi
assert_contains "$scratch/invalid-major.out" 'backend.image.digest'

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

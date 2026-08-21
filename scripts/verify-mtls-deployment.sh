#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="chart/noves-canton-data-app"
scratch="$(mktemp -d)"
test_exports_volume=""
compose_root=""
cleanup() {
  if [[ -n "$compose_root" && -f "$compose_root/compose.yaml" && -f "$compose_root/.env.example" ]]; then
    docker compose --env-file "$compose_root/.env.example" \
      -f "$compose_root/compose.yaml" down --remove-orphans >/dev/null 2>&1 || true
  fi
  if [[ -n "$test_exports_volume" ]]; then
    docker volume rm -f "$test_exports_volume" >/dev/null 2>&1 || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'echo "deployment verification failed at line $LINENO" >&2' ERR

run_helm() {
  if command -v helm >/dev/null 2>&1; then
    (cd "$repo_root" && helm "$@")
  else
    docker run --rm -v "$repo_root:/work" -w /work alpine/helm:3.18.4 "$@"
  fi
}

common=(
  --namespace validator
  --set-string oidc.provider=auth0
  --set-string oidc.appUrl=https://data.example.com
  --set-string oidc.auth0.domain=auth.example.com
  --set-string oidc.auth0.clientId=test-client
  --set-string oidc.auth0.audience=test-audience
)

run_helm lint "$chart" "${common[@]}"

multi_node_values="$scratch/helm-multi-node-values.yaml"
cat >"$multi_node_values" <<'YAML'
canton:
  nodes:
    - id: node-z
      addr: participant-z:5001
      synchronizerAlias: global
      tls:
        existingSecret: node-z-ledger-tls
        certificateKey: ca.crt
        clientCertificateKey: client.crt
        clientPrivateKeyKey: client.key
        serverName: ledger-z.example.com
      m2mIndexing:
        mode: global
    - id: node-a
      addr: participant-a:5001
      synchronizerAlias: global
      tls:
        existingSecret: ""
        certificateKey: ""
        clientCertificateKey: ""
        clientPrivateKeyKey: ""
        serverName: ""
      m2mIndexing:
        mode: clientCredentials
        tokenEndpoint: https://auth.example/token
        clientId: node-a-m2m-indexing
        audience: ""
        scope: ""
        existingSecret: node-a-m2m-indexing
        clientSecretKey: client-secret
        staticTokenKey: token
    - id: node-b
      addr: participant-b:5001
      synchronizerAlias: global
      tls:
        existingSecret: ""
        certificateKey: ""
        clientCertificateKey: ""
        clientPrivateKeyKey: ""
        serverName: ""
      m2mIndexing:
        mode: staticToken
        tokenEndpoint: ""
        clientId: ""
        audience: ""
        scope: ""
        existingSecret: node-b-m2m-indexing
        clientSecretKey: client-secret
        staticTokenKey: token
YAML
multi_node_render="$scratch/helm-multi-node.yaml"
run_helm template cda "$chart" "${common[@]}" -f "$multi_node_values" >"$multi_node_render"
rg -q '"primaryNodeId": "node-z"' "$multi_node_render"
frontend_deployment="$scratch/helm-frontend-deployment.yaml"
awk 'BEGIN { RS="---" } /app.kubernetes.io\/component: frontend/ && /kind: Deployment/ { print; exit }' \
  "$multi_node_render" >"$frontend_deployment"
rg -Uq 'readinessProbe:\n[[:space:]]+httpGet:\n[[:space:]]+path: /health' "$frontend_deployment"
rg -Uq 'livenessProbe:\n[[:space:]]+httpGet:\n[[:space:]]+path: /health' "$frontend_deployment"
for node_id in node-z node-a node-b; do
  rg -q "\"$node_id\":" "$multi_node_render"
done
rg -q '"client_secret_file": "/m2m-indexing-secrets/node-a/client-secret"' "$multi_node_render"
rg -q '"static_token_file": "/m2m-indexing-secrets/node-b/token"' "$multi_node_render"
rg -q 'secretName: node-z-ledger-tls' "$multi_node_render"
rg -q 'secretName: node-a-m2m-indexing' "$multi_node_render"
rg -q 'secretName: node-b-m2m-indexing' "$multi_node_render"
if awk 'BEGIN { RS="---" } /app.kubernetes.io\/component: (frontend|database)/ && /node-z-ledger-tls|node-a-m2m-indexing|node-b-m2m-indexing|m2m-indexing-secrets\/|certificates\/nodes\// { found=1 } END { exit found ? 0 : 1 }' "$multi_node_render"; then
  echo "frontend or database unexpectedly received node credential configuration" >&2
  exit 1
fi

multi_node_migration_render="$scratch/helm-multi-node-migration.yaml"
run_helm template cda "$chart" "${common[@]}" -f "$multi_node_values" \
  --set migration.enabled=true \
  --set-string migration.sourceVersion=3.16.1 \
  --set migration.backupConfirmed=true \
  --set migration.oldWorkloadStopped=true \
  --set-string migration.existingClaim=v3-database-pvc >"$multi_node_migration_render"
rg -q 'claimName: v3-database-pvc' "$multi_node_migration_render"
rg -q 'name: DATABASE_EXPECTED_SOURCE' "$multi_node_migration_render"
rg -q 'secretName: node-z-ledger-tls' "$multi_node_migration_render"
rg -q 'secretName: node-a-m2m-indexing' "$multi_node_migration_render"
rg -q 'secretName: node-b-m2m-indexing' "$multi_node_migration_render"

malformed_secondary_values="$scratch/helm-malformed-secondary-node-values.yaml"
cat >"$malformed_secondary_values" <<'YAML'
canton:
  nodes:
    - id: primary
      addr: participant-primary:5001
      tls: {}
      m2mIndexing: { mode: global }
    - id: broken-secondary
      addr: participant-secondary:5001
      tls: {}
      m2mIndexing:
        mode: clientCredentials
        clientId: secondary-m2m-indexing
        existingSecret: secondary-m2m-indexing-secret
YAML
if run_helm template cda "$chart" "${common[@]}" -f "$malformed_secondary_values" >"$scratch/malformed-secondary.out" 2>&1; then
  echo "malformed non-primary canton.nodes entry unexpectedly rendered" >&2
  exit 1
fi
rg -q 'broken-secondary.*tokenEndpoint' "$scratch/malformed-secondary.out"

duplicate_node_values="$scratch/helm-duplicate-node-values.yaml"
cat >"$duplicate_node_values" <<'YAML'
canton:
  nodes:
    - id: repeated
      addr: participant-a:5001
      tls: {}
      m2mIndexing: { mode: global }
    - id: repeated
      addr: participant-b:5001
      tls: {}
      m2mIndexing: { mode: global }
YAML
if run_helm template cda "$chart" "${common[@]}" -f "$duplicate_node_values" >"$scratch/duplicate-node.out" 2>&1; then
  echo "duplicate canton.nodes ids unexpectedly rendered" >&2
  exit 1
fi
rg -q 'duplicate id.*repeated' "$scratch/duplicate-node.out"

unsafe_node_values="$scratch/helm-unsafe-node-values.yaml"
cat >"$unsafe_node_values" <<'YAML'
canton:
  nodes:
    - id: ../escape
      addr: participant:5001
      tls: {}
      m2mIndexing: { mode: global }
YAML
if run_helm template cda "$chart" "${common[@]}" -f "$unsafe_node_values" >"$scratch/unsafe-node.out" 2>&1; then
  echo "path-unsafe canton.nodes id unexpectedly rendered" >&2
  exit 1
fi
rg -q 'canton.nodes.0.id' "$scratch/unsafe-node.out"

optional_identity="$scratch/helm-optional-identity.yaml"
run_helm template cda "$chart" "${common[@]}" >"$optional_identity"
rg -q 'value: "http://validator-app:5003/api/validator"' "$optional_identity"
rg -q 'name: M2M_TOKEN_ENDPOINT' "$optional_identity"
if rg -q '"m2mIndexing":' "$optional_identity"; then
  echo "global M2M indexing unexpectedly rendered a node credential block" >&2
  exit 1
fi

node0=(
  --set-string 'canton.nodes[0].id=main-node'
  --set-string 'canton.nodes[0].addr=participant:5001'
  --set-string 'canton.nodes[0].tls.existingSecret='
  --set-string 'canton.nodes[0].m2mIndexing.mode=global'
)

system_trust="$scratch/helm-system-trust.yaml"
run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string 'canton.nodes[0].tls.existingSecret=ledger-mtls' \
  --set-string 'canton.nodes[0].tls.certificateKey=' \
  --set-string 'canton.nodes[0].tls.clientCertificateKey=client.crt' \
  --set-string 'canton.nodes[0].tls.clientPrivateKeyKey=client.key' \
  --set-string 'canton.nodes[0].tls.serverName=ledger.example.com' >"$system_trust"
rg -q '"client_cert_file": "/certificates/nodes/main-node/client.crt"' "$system_trust"
rg -q '"client_key_file": "/certificates/nodes/main-node/client.key"' "$system_trust"
rg -q '"tls_server_name": "ledger.example.com"' "$system_trust"
rg -q 'defaultMode: 0440' "$system_trust"
rg -q 'key: client.crt' "$system_trust"
rg -q 'key: client.key' "$system_trust"
if rg -q '"cert_file"|key: ca.crt' "$system_trust"; then
  echo "system-trust mTLS unexpectedly rendered a custom CA" >&2
  exit 1
fi

custom_ca="$scratch/helm-custom-ca.yaml"
run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string 'canton.nodes[0].tls.existingSecret=ledger-mtls' \
  --set-string 'canton.nodes[0].tls.certificateKey=ca.crt' \
  --set-string 'canton.nodes[0].tls.clientCertificateKey=client.crt' \
  --set-string 'canton.nodes[0].tls.clientPrivateKeyKey=client.key' >"$custom_ca"
rg -q '"cert_file": "/certificates/nodes/main-node/ca.crt"' "$custom_ca"
rg -q 'key: ca.crt' "$custom_ca"

node_client_credentials="$scratch/helm-node-client-credentials.yaml"
run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string m2mIndexing.existingSecret= \
  --set-string 'canton.nodes[0].m2mIndexing.mode=clientCredentials' \
  --set-string 'canton.nodes[0].m2mIndexing.tokenEndpoint=https://auth.example/token' \
  --set-string 'canton.nodes[0].m2mIndexing.clientId=node-m2m-indexing' \
  --set-string 'canton.nodes[0].m2mIndexing.existingSecret=node-m2m-indexing-credentials' \
  --set-string 'canton.nodes[0].m2mIndexing.clientSecretKey=client-secret' >"$node_client_credentials"
rg -q '"token_endpoint": "https://auth.example/token"' "$node_client_credentials"
rg -q '"client_id": "node-m2m-indexing"' "$node_client_credentials"
rg -q '"audience": ""' "$node_client_credentials"
rg -q '"scope": ""' "$node_client_credentials"
rg -q '"client_secret_file": "/m2m-indexing-secrets/main-node/client-secret"' "$node_client_credentials"
rg -q 'name: M2M_INDEXER_ENABLED' "$node_client_credentials"
rg -q 'name: node-m2m-indexing-' "$node_client_credentials"
rg -q 'secretName: node-m2m-indexing-credentials' "$node_client_credentials"
rg -q 'mountPath: "/m2m-indexing-secrets/main-node"' "$node_client_credentials"
if rg -q 'name: M2M_(TOKEN_ENDPOINT|CLIENT_ID|CLIENT_SECRET|AUDIENCE|SCOPE)' "$node_client_credentials"; then
  echo "explicit node credentials must not render global M2M environment variables" >&2
  exit 1
fi
if awk 'BEGIN { RS="---" } /kind: Deployment/ && /app.kubernetes.io\/component: frontend/ && /m2m-indexing-node-credential|m2m-indexing-secrets|node-m2m-indexing-credentials/ { found=1 } END { exit found ? 0 : 1 }' "$node_client_credentials"; then
  echo "frontend unexpectedly received node M2M indexing secret configuration" >&2
  exit 1
fi

node_static_token="$scratch/helm-node-static-token.yaml"
run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string m2mIndexing.existingSecret= \
  --set-string 'canton.nodes[0].m2mIndexing.mode=staticToken' \
  --set-string 'canton.nodes[0].m2mIndexing.existingSecret=node-m2m-indexing-token' \
  --set-string 'canton.nodes[0].m2mIndexing.staticTokenKey=token' >"$node_static_token"
rg -q '"static_token_file": "/m2m-indexing-secrets/main-node/token"' "$node_static_token"
rg -q 'secretName: node-m2m-indexing-token' "$node_static_token"
rg -q 'name: M2M_INDEXER_ENABLED' "$node_static_token"
if rg -q 'name: M2M_(TOKEN_ENDPOINT|CLIENT_ID|CLIENT_SECRET|AUDIENCE|SCOPE)' "$node_static_token"; then
  echo "explicit node token must not render global M2M environment variables" >&2
  exit 1
fi

if run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string 'canton.nodes[0].m2mIndexing.mode=staticToken' \
  --set-string 'canton.nodes[0].m2mIndexing.existingSecret=node-m2m-indexing-token' \
  --set-string 'canton.nodes[0].m2mIndexing.tokenEndpoint=https://auth.example/token' >"$scratch/incompatible-node-credential.out" 2>&1; then
  echo "incompatible static and client credential settings unexpectedly rendered" >&2
  exit 1
fi
rg -q 'staticToken' "$scratch/incompatible-node-credential.out"

if run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string 'canton.nodes[0].m2mIndexing.mode=clientCredentials' \
  --set-string 'canton.nodes[0].m2mIndexing.existingSecret=node-m2m-indexing-credentials' >"$scratch/incomplete-node-credential.out" 2>&1; then
  echo "incomplete node client credentials unexpectedly rendered" >&2
  exit 1
fi
rg -q 'tokenEndpoint' "$scratch/incomplete-node-credential.out"

if run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string m2mIndexing.existingSecret= >"$scratch/global-missing-secret.out" 2>&1; then
  echo "global M2M indexing without m2mIndexing.existingSecret unexpectedly rendered" >&2
  exit 1
fi
rg -q 'm2mIndexing.existingSecret' "$scratch/global-missing-secret.out"

if run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string 'canton.nodes[0].tls.existingSecret=ledger-mtls' \
  --set-string 'canton.nodes[0].tls.clientCertificateKey=client.crt' \
  --set-string 'canton.nodes[0].tls.clientPrivateKeyKey=' >"$scratch/partial.out" 2>&1; then
  echo "partial Helm client identity unexpectedly rendered" >&2
  exit 1
fi
rg -q 'clientCertificateKey.*clientPrivateKeyKey' "$scratch/partial.out"

if run_helm template cda "$chart" "${common[@]}" "${node0[@]}" \
  --set-string 'canton.nodes[0].tls.existingSecret=' \
  --set-string 'canton.nodes[0].tls.clientCertificateKey=client.crt' \
  --set-string 'canton.nodes[0].tls.clientPrivateKeyKey=client.key' >"$scratch/no-secret.out" 2>&1; then
  echo "Helm client identity without certificateSecret unexpectedly rendered" >&2
  exit 1
fi
rg -q 'tls.existingSecret' "$scratch/no-secret.out"

compose_root="$scratch/compose"
cp -R "$repo_root/docker-compose" "$compose_root"
mkdir -p "$compose_root/.state/certificates" "$compose_root/.state/m2m-indexing-secrets"
touch "$compose_root/.state/m2m-indexing.env" \
  "$compose_root/.state/accounting.env" \
  "$compose_root/.state/storage.env"
cp "$compose_root/config/nodes-config.json" "$compose_root/.state/nodes-config.json"
docker compose --env-file "$compose_root/.env.example" \
  -f "$compose_root/compose.yaml" config >"$scratch/compose.yaml"
rg -q 'SCAN_PROXY_URL: http://validator:5003/api/validator' "$scratch/compose.yaml"
rg -q 'M2M_INDEXER_ENABLED: "true"' "$scratch/compose.yaml"
backend_image_from_env="$(awk -F= '$1 == "BACKEND_IMAGE" { print $2 }' "$compose_root/.env.example")"
backend_image_fallback="$(sed -n 's|.*${BACKEND_IMAGE:-\([^}]*\)}.*|\1|p' "$compose_root/compose.yaml")"
if [[ "$backend_image_from_env" != "$backend_image_fallback" ]]; then
  echo "Compose .env.example backend image must match the Compose fallback" >&2
  exit 1
fi
frontend_image_from_env="$(awk -F= '$1 == "FRONTEND_IMAGE" { print $2 }' "$compose_root/.env.example")"
frontend_image_fallback="$(sed -n 's|.*${FRONTEND_IMAGE:-\([^}]*\)}.*|\1|p' "$compose_root/compose.yaml")"
if [[ "$frontend_image_from_env" != "$frontend_image_fallback" ]]; then
  echo "Compose .env.example frontend image must match the Compose fallback" >&2
  exit 1
fi
rg -q 'source: .*\.state/certificates' "$scratch/compose.yaml"
rg -q 'target: /certificates' "$scratch/compose.yaml"
rg -q 'source: .*\.state/m2m-indexing-secrets' "$scratch/compose.yaml"
rg -q 'target: /m2m-indexing-secrets' "$scratch/compose.yaml"
rg -Uq 'path: \.\/\.state\/accounting\.env\n[[:space:]]+required: true' "$repo_root/docker-compose/compose.yaml"
rg -q 'read_only: true' "$scratch/compose.yaml"
rg -q 'create_host_path: false' "$scratch/compose.yaml"

# shellcheck source=lib/canton-certificates.sh
source "$repo_root/scripts/lib/canton-certificates.sh"
# shellcheck source=lib/m2m-indexing-secrets.sh
source "$repo_root/scripts/lib/m2m-indexing-secrets.sh"
# shellcheck source=lib/export-storage.sh
source "$repo_root/scripts/lib/export-storage.sh"
certificate_root="$scratch/certificate-validation"
mkdir -p "$certificate_root"
touch "$certificate_root/client.crt" "$certificate_root/client.key"
nodes_file="$scratch/nodes-config.json"
printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001","client_cert_file":"/certificates/client.crt","client_key_file":"/certificates/client.key"}}}' >"$nodes_file"
validate_canton_certificate_files "$nodes_file" "$certificate_root"
[[ "${canton_certificate_container_paths[*]}" == *"/certificates/client.crt"* ]]

printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001","client_cert_file":"/certificates/client.crt","client_key_file":"/certificates/missing.key"}}}' >"$nodes_file"
if validate_canton_certificate_files "$nodes_file" "$certificate_root" \
  >"$scratch/missing.out" 2>&1; then
  echo "missing Compose certificate unexpectedly passed validation" >&2
  exit 1
fi
rg -q '/certificates/missing.key' "$scratch/missing.out"

permissions_root="$scratch/certificate-permissions"
mkdir -p "$permissions_root"
touch "$permissions_root/client.crt" "$permissions_root/client.key"
chmod 755 "$permissions_root"
chmod 644 "$permissions_root/client.crt" "$permissions_root/client.key"
cat >"$scratch/permissions-compose.yaml" <<'YAML'
services:
  backend:
    image: alpine:3.22
    volumes:
      - type: bind
        source: ${CERTIFICATE_ROOT}
        target: /certificates
        read_only: true
YAML
printf 'CERTIFICATE_ROOT=%s\n' "$permissions_root" >"$scratch/permissions.env"
secure_canton_certificate_files \
  "$scratch/permissions.env" \
  "$scratch/permissions-compose.yaml" \
  "$permissions_root" \
  /certificates/client.crt \
  /certificates/client.key
docker compose --env-file "$scratch/permissions.env" \
  -f "$scratch/permissions-compose.yaml" run --rm --no-deps \
  --user 0:0 --entrypoint /bin/sh backend -ec '
    test "$(stat -c %a /certificates)" = 750
    test "$(stat -c %g /certificates)" = 1654
    test "$(stat -c %a /certificates/client.key)" = 440
    test "$(stat -c %g /certificates/client.key)" = 1654
  '

m2m_indexing_permissions_root="$scratch/m2m_indexing-secret-permissions"
mkdir -p "$m2m_indexing_permissions_root/main-node"
printf '%s\n' 'disposable-static-token' >"$m2m_indexing_permissions_root/main-node/token"
m2m_indexing_nodes_file="$scratch/m2m-indexing-nodes-config.json"
printf '%s\n' '{"nodes":{"main-node":{"m2mIndexing":{"static_token_file":"/m2m-indexing-secrets/main-node/token"}}}}' >"$m2m_indexing_nodes_file"
validate_m2m_indexing_secret_files "$m2m_indexing_nodes_file" "$m2m_indexing_permissions_root"
secure_m2m_indexing_secret_files \
  "$scratch/permissions.env" \
  "$scratch/permissions-compose.yaml" \
  "$m2m_indexing_permissions_root" \
  "${m2m_indexing_secret_container_paths[@]}"
docker run --rm --user 1654:1654 \
  --volume "$m2m_indexing_permissions_root:/m2m-indexing-secrets:ro" \
  --entrypoint /bin/sh alpine:3.22 -ec '
    test "$(stat -c %a /m2m-indexing-secrets)" = 750
    test "$(stat -c %g /m2m-indexing-secrets)" = 1654
    test "$(stat -c %a /m2m-indexing-secrets/main-node)" = 750
    test "$(stat -c %g /m2m-indexing-secrets/main-node)" = 1654
    test "$(stat -c %a /m2m-indexing-secrets/main-node/token)" = 440
    test "$(stat -c %g /m2m-indexing-secrets/main-node/token)" = 1654
    test -r /m2m-indexing-secrets/main-node/token
  '

printf '%s\n' '{"nodes":{"main-node":{"m2mIndexing":{"static_token_file":"/tmp/token"}}}}' >"$m2m_indexing_nodes_file"
if validate_m2m_indexing_secret_files "$m2m_indexing_nodes_file" "$m2m_indexing_permissions_root" >"$scratch/m2m_indexing-path.out" 2>&1; then
  echo "M2M indexing secret outside /m2m-indexing-secrets unexpectedly validated" >&2
  exit 1
fi
rg -q '/m2m-indexing-secrets' "$scratch/m2m_indexing-path.out"

m2m_indexing_symlink_target="$scratch/m2m_indexing-symlink-target"
m2m_indexing_symlink_root="$scratch/m2m_indexing-symlink-root"
mkdir -p "$m2m_indexing_symlink_target/main-node"
printf '%s\n' 'must-not-be-repermissioned' >"$m2m_indexing_symlink_target/main-node/token"
chmod 0700 "$m2m_indexing_symlink_target" "$m2m_indexing_symlink_target/main-node"
chmod 0600 "$m2m_indexing_symlink_target/main-node/token"
ln -s "$m2m_indexing_symlink_target" "$m2m_indexing_symlink_root"
printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001","m2mIndexing":{"static_token_file":"/m2m-indexing-secrets/main-node/token"}}}}' >"$m2m_indexing_nodes_file"
m2m_indexing_target_mode_before="$(stat -f '%Lp' "$m2m_indexing_symlink_target" 2>/dev/null || stat -c '%a' "$m2m_indexing_symlink_target")"
m2m_indexing_file_mode_before="$(stat -f '%Lp' "$m2m_indexing_symlink_target/main-node/token" 2>/dev/null || stat -c '%a' "$m2m_indexing_symlink_target/main-node/token")"
if validate_m2m_indexing_secret_files "$m2m_indexing_nodes_file" "$m2m_indexing_symlink_root" >"$scratch/m2m_indexing-symlink-validate.out" 2>&1; then
  echo "symlinked M2M indexing secret root unexpectedly validated" >&2
  exit 1
fi
rg -q 'real directory' "$scratch/m2m_indexing-symlink-validate.out"
if secure_m2m_indexing_secret_files \
  "$scratch/permissions.env" \
  "$scratch/permissions-compose.yaml" \
  "$m2m_indexing_symlink_root" \
  /m2m-indexing-secrets/main-node/token >"$scratch/m2m_indexing-symlink-secure.out" 2>&1; then
  echo "symlinked M2M indexing secret root unexpectedly reached privileged preparation" >&2
  exit 1
fi
rg -q 'real directory' "$scratch/m2m_indexing-symlink-secure.out"
m2m_indexing_target_mode_after="$(stat -f '%Lp' "$m2m_indexing_symlink_target" 2>/dev/null || stat -c '%a' "$m2m_indexing_symlink_target")"
m2m_indexing_file_mode_after="$(stat -f '%Lp' "$m2m_indexing_symlink_target/main-node/token" 2>/dev/null || stat -c '%a' "$m2m_indexing_symlink_target/main-node/token")"
[[ "$m2m_indexing_target_mode_after" == "$m2m_indexing_target_mode_before" ]]
[[ "$m2m_indexing_file_mode_after" == "$m2m_indexing_file_mode_before" ]]

rg -q 'secure_canton_certificate_files' "$repo_root/scripts/install-compose.sh"
rg -q 'secure_m2m_indexing_secret_files' "$repo_root/scripts/install-compose.sh"
rg -q 'restart backend' "$repo_root/docs/docker-compose.md"
rg -q 'rollout restart' "$repo_root/docs/helm.md"
rg -q 'old root followed by the new root' "$repo_root/docs/docker-compose.md"
rg -q 'old and new roots' "$repo_root/docs/helm.md"
rg -q 'M2M_INDEXER_ENABLED=true.*explicit' "$repo_root/docs/environment-variables.md"

# The backend is the sole owner of exported artifacts. A fresh Docker named
# volume is root-owned, so the installer must hand it to the non-root backend
# before it starts. The frontend deliberately has no artifact-volume mount.
compose_json="$scratch/compose.json"
docker compose --env-file "$compose_root/.env.example" \
  -f "$compose_root/compose.yaml" config --format json >"$compose_json"
exports_volume="$(compose_export_volume_name "$compose_json")"
[[ "$exports_volume" == "noves-canton-data-app-v4-exports" ]]
[[ "$(jq -r '.volumes.exports.external' "$compose_json")" == "true" ]]
if jq -e '.services.frontend.volumes[]? | select(.target == "/exports")' "$compose_json" >/dev/null; then
  echo "frontend must not mount the export volume" >&2
  exit 1
fi
if jq -e '.services.frontend.volumes[]? | select(.target == "/m2m-indexing-secrets")' "$compose_json" >/dev/null; then
  echo "frontend must not mount M2M indexing secrets" >&2
  exit 1
fi
rg -q 'prepare_export_volume' "$repo_root/scripts/install-compose.sh"
rg -q 'backend owns the named export volume' "$repo_root/docs/docker-compose.md"

test_exports_volume="cda-v4-export-verify-$RANDOM-$RANDOM"
test_env="$scratch/export-volume.env"
cp "$compose_root/.env.example" "$test_env"
printf 'EXPORTS_VOLUME=%s\n' "$test_exports_volume" >>"$test_env"
prepare_export_volume "$test_env" "$compose_root/compose.yaml"
backend_image="$(docker compose --env-file "$test_env" -f "$compose_root/compose.yaml" \
  config --format json | jq -er '.services.backend.image')"
docker run --rm --user 1654:1654 --volume "$test_exports_volume:/exports" \
  --entrypoint /bin/sh "$backend_image" -ec '
    test -w /exports
    test -w /exports/accounting
    touch /exports/accounting/ownership-probe
  '

echo "mTLS deployment verification passed"

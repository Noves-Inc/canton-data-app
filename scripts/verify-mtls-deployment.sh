#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="chart/noves-canton-data-app"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

run_helm() {
  if command -v helm >/dev/null 2>&1; then
    (cd "$repo_root" && helm "$@")
  else
    docker run --rm -v "$repo_root:/work" -w /work alpine/helm:3.18.4 "$@"
  fi
}

common=(
  --namespace validator
  --set-string canton.expectedParticipantId=participant::test
  --set-string oidc.provider=auth0
  --set-string oidc.appUrl=https://data.example.com
  --set-string oidc.auth0.domain=auth.example.com
  --set-string oidc.auth0.clientId=test-client
  --set-string oidc.auth0.audience=test-audience
)

run_helm lint "$chart" "${common[@]}"

system_trust="$scratch/helm-system-trust.yaml"
run_helm template cda "$chart" "${common[@]}" \
  --set-string canton.certificateSecret=ledger-mtls \
  --set-string canton.certificateKey= \
  --set-string canton.clientCertificateKey=client.crt \
  --set-string canton.clientPrivateKeyKey=client.key \
  --set-string canton.tlsServerName=ledger.example.com >"$system_trust"
rg -q '"client_cert_file": "/certificates/client.crt"' "$system_trust"
rg -q '"client_key_file": "/certificates/client.key"' "$system_trust"
rg -q '"tls_server_name": "ledger.example.com"' "$system_trust"
rg -q 'defaultMode: 0440' "$system_trust"
rg -q 'key: client.crt' "$system_trust"
rg -q 'key: client.key' "$system_trust"
if rg -q '"cert_file"|key: ca.crt' "$system_trust"; then
  echo "system-trust mTLS unexpectedly rendered a custom CA" >&2
  exit 1
fi

custom_ca="$scratch/helm-custom-ca.yaml"
run_helm template cda "$chart" "${common[@]}" \
  --set-string canton.certificateSecret=ledger-mtls \
  --set-string canton.certificateKey=ca.crt \
  --set-string canton.clientCertificateKey=client.crt \
  --set-string canton.clientPrivateKeyKey=client.key >"$custom_ca"
rg -q '"cert_file": "/certificates/ca.crt"' "$custom_ca"
rg -q 'key: ca.crt' "$custom_ca"

if run_helm template cda "$chart" "${common[@]}" \
  --set-string canton.certificateSecret=ledger-mtls \
  --set-string canton.clientCertificateKey=client.crt \
  --set-string canton.clientPrivateKeyKey= >"$scratch/partial.out" 2>&1; then
  echo "partial Helm client identity unexpectedly rendered" >&2
  exit 1
fi
rg -q 'clientCertificateKey.*clientPrivateKeyKey' "$scratch/partial.out"

if run_helm template cda "$chart" "${common[@]}" \
  --set-string canton.certificateSecret= \
  --set-string canton.clientCertificateKey=client.crt \
  --set-string canton.clientPrivateKeyKey=client.key >"$scratch/no-secret.out" 2>&1; then
  echo "Helm client identity without certificateSecret unexpectedly rendered" >&2
  exit 1
fi
rg -q 'certificateSecret' "$scratch/no-secret.out"

compose_root="$scratch/compose"
cp -R "$repo_root/docker-compose" "$compose_root"
mkdir -p "$compose_root/.state/certificates"
touch "$compose_root/.state/capture.env" \
  "$compose_root/.state/accounting.env" \
  "$compose_root/.state/storage.env"
cp "$compose_root/config/nodes-config.json" "$compose_root/.state/nodes-config.json"
docker compose --env-file "$compose_root/.env.example" \
  -f "$compose_root/compose.yaml" config >"$scratch/compose.yaml"
rg -q 'source: .*\.state/certificates' "$scratch/compose.yaml"
rg -q 'target: /certificates' "$scratch/compose.yaml"
rg -q 'read_only: true' "$scratch/compose.yaml"
rg -q 'create_host_path: false' "$scratch/compose.yaml"

# shellcheck source=lib/canton-certificates.sh
source "$repo_root/scripts/lib/canton-certificates.sh"
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

echo "mTLS deployment verification passed"

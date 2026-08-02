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

optional_identity="$scratch/helm-optional-identity.yaml"
run_helm template cda "$chart" "${common[@]}" >"$optional_identity"
if rg -q '"expectedParticipantId"' "$optional_identity"; then
  echo "optional participant identity unexpectedly rendered" >&2
  exit 1
fi
rg -q 'value: "http://validator-app:5003/api/validator"' "$optional_identity"

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
rg -q 'SCAN_PROXY_URL: http://validator:5003/api/validator' "$scratch/compose.yaml"
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
rg -q 'read_only: true' "$scratch/compose.yaml"
rg -q 'create_host_path: false' "$scratch/compose.yaml"

# shellcheck source=lib/canton-certificates.sh
source "$repo_root/scripts/lib/canton-certificates.sh"
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

rg -q 'secure_canton_certificate_files' "$repo_root/scripts/install-compose.sh"
rg -q 'restart backend' "$repo_root/docs/docker-compose.md"
rg -q 'rollout restart' "$repo_root/docs/helm.md"
rg -q 'old root followed by the new root' "$repo_root/docs/docker-compose.md"
rg -q 'old and new roots' "$repo_root/docs/helm.md"

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

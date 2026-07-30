#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'documentation test failed: %s\n' "$*" >&2
  exit 1
}

required=(
  readme.md
  docs/helm.md
  docs/docker-compose.md
  docs/setup-wizard.md
  docs/authentication/auth0.md
  docs/authentication/keycloak.md
  docs/migrate-v3.16.1.md
  docs/upgrades.md
  docs/security.md
  docs/streaming.md
  docs/screenshots/README.md
  docs/screenshots/manifest.yaml
)
for path in "${required[@]}"; do
  [[ -s "$repo_root/$path" ]] || fail "missing required file: $path"
done

customer_docs=("$repo_root/readme.md" "$repo_root/encryption_at_rest.md")
for path in "${required[@]}"; do
  customer_docs+=("$repo_root/$path")
done
if rg -n 'Noves App v[0-9]|\bData App\b|Canton Data App' "${customer_docs[@]}"; then
  fail 'customer documentation uses an obsolete or awkward product name.'
fi

while IFS= read -r markdown; do
  while IFS= read -r target; do
    target="${target#<}"
    target="${target%>}"
    case "$target" in
      ""|\#*|http://*|https://*|mailto:*) continue ;;
    esac
    target="${target%%#*}"
    [[ -e "$(dirname "$markdown")/$target" ]] ||
      fail "broken link in ${markdown#"$repo_root/"}: $target"
  done < <(perl -ne 'while (/\]\(([^)]+)\)/g) { print "$1\n" }' "$markdown")
done < <(find "$repo_root" -name '*.md' -type f -print)

if rg -ni 'screenshot[- ]slot' "$repo_root/docs/authentication"; then
  fail 'authentication guides expose screenshot authoring labels.'
fi

internal_language='py''thon'
if rg -ni "$internal_language|3\\.15\\.0" \
  "$repo_root/readme.md" "$repo_root/docs"; then
  fail 'customer documentation exposes an internal migration detail.'
fi
if rg -ni 'ghcr\\.io/noves-inc/canton-translate|externalDatabase|external database' \
  "$repo_root/readme.md" "$repo_root/docs" "$repo_root/chart" "$repo_root/docker-compose"; then
  fail 'customer artifacts contain an obsolete image or unsupported database option.'
fi
if rg -ni 'tag:[[:space:]]+latest' "$repo_root/chart/noves-canton-data-app"; then
  fail 'the chart defaults to a moving image tag.'
fi
if rg -n 'canton-data-app/main/install\.sh' "$repo_root/readme.md" "$repo_root/docs"; then
  fail 'a v4 quick start downloads an installer from the moving main branch.'
fi

startup_contract_files=(
  "$repo_root/scripts/install-compose.sh"
  "$repo_root/docs/helm.md"
  "$repo_root/docs/docker-compose.md"
  "$repo_root/docs/migrate-v3.16.1.md"
  "$repo_root/docs/upgrades.md"
)
if rg -n '/startupStatus' "${startup_contract_files[@]}"; then
  fail 'operator-facing artifacts use the nonexistent startupStatus route.'
fi
for path in "${startup_contract_files[@]}"; do
  rg -Fq '/startup-status' "$path" ||
    fail "${path#"$repo_root/"} is missing the canonical startup-status route."
done

for contract in \
  'novesGateway.existingSecret' \
  '.state/gateway.env' \
  'NOVES_GATEWAY_AUTH_TOKEN_FILE' \
  'NOVES_PUBLIC_API_URL' \
  'https://api.canton.noves.fi' \
  '/dev/tty' \
  'session-token' \
  'release-manifest.json' \
  'DATABASE_MAX_PARALLEL_WORKERS_PER_GATHER' \
  'READ_MODEL_TOTAL_CAPACITY' \
  'BACKGROUND_INDEXING_DUTY_PERCENT' \
  'STREAM_PAGE_SIZE' \
  'splice-app-validator-ledger-api-auth' \
  'ADMIN_DISCOVERY_URL' \
  "jq -er '.token_endpoint'" \
  '--participant-admin-secret' \
  '--validator-container' \
  'grpcurl -expand-headers' \
  'memory only' \
  'final deployment' \
  'routing.provider' \
  'routing.backend.enabled' \
  'api.data.example.com' \
  'BACKEND_BIND_ADDRESS' \
  '/docs/v1/openapi.json' \
  '127.0.0.1:8090' \
  'ACCOUNTING_TOKEN_ENCRYPTION_KEY' \
  '/api/v2/capture/status' \
  'kubectl get ingressclass' \
  'kubectl get pvc' \
  'imagePullSecrets' \
  'DATABASE_EXPECTED_SOURCE' \
  'persistentVolumeClaim.claimName' \
  'Keep `migration.enabled: true`'
do
  rg -Fq -- "$contract" "$repo_root/readme.md" "$repo_root/docs" ||
    fail "operator documentation is missing: $contract"
done

while IFS='|' read -r path contract; do
  rg -Fq -- "$contract" "$repo_root/$path" ||
    fail "$path is missing the public backend contract: $contract"
done <<'EOF'
readme.md|api.data.example.com
docs/helm.md|routing.backend.enabled
docs/helm.md|/docs/v1/openapi.json
docs/docker-compose.md|BACKEND_BIND_ADDRESS
docs/docker-compose.md|127.0.0.1:8090
docs/docker-compose.md|http://validator:5003
docs/docker-compose.md|CANTON_NETWORK=testnet
docs/docker-compose.md|BACKEND_IMAGE=
docs/docker-compose.md|APP_INSTALL_DIR
docs/docker-compose.md|.state/accounting.env
docs/docker-compose.md|AUTH_WELLKNOWN_URL
docs/docker-compose.md|.token_endpoint
docs/docker-compose.md|GetParticipantId
docs/docker-compose.md|CreateUser
docs/docker-compose.md|ListUserRights
docs/docker-compose.md|participant_id
docs/docker-compose.md|.state/gateway.env
docs/docker-compose.md|storage.env.example
docs/docker-compose.md|docker-compose/nginx/cda.conf.example
docs/docker-compose.md|`noves-canton-data-app-v4-exports`
docs/security.md|routing.backend.enabled
docs/authentication/keycloak.md|VITE_KEYCLOAK_URL=
docs/authentication/keycloak.md|noves-canton-data-app-capture
docs/authentication/keycloak.md|**Settings > Capability config**
docs/authentication/keycloak.md|**PKCE Method** to `S256`
docs/authentication/keycloak.md|Select **Add client scope**
docs/authentication/keycloak.md|choose **Default**
docs/authentication/keycloak.md|Leave **Root URL** and **Home URL** blank
docs/authentication/keycloak.md|Select **Configure a new mapper**
docs/authentication/keycloak.md|**Name:** `ledger-api-audience`
EOF

if rg -Fq 'validator-app:5003' \
  "$repo_root/docs/docker-compose.md" "$repo_root/docker-compose"; then
  fail 'Compose documentation or manifests still use the Helm validator service name.'
fi

if rg -ni 'Capture only|Redact' "$repo_root/docs/authentication"; then
  fail 'authentication guides expose screenshot-production instructions.'
fi

if rg -n '\bCDA\b|CDA_[A-Z0-9_]*' \
  "$repo_root/readme.md" "$repo_root/docs" \
  "$repo_root/docker-compose/.env.example" --glob '*.md'; then
  fail 'public documentation uses the retired product name or variable prefix.'
fi

rg -Fq './scripts/install-compose.sh' "$repo_root/readme.md" ||
  fail 'the README standard Compose path does not use the installer'
rg -Fq -- '--standard' "$repo_root/readme.md" ||
  fail 'the README standard Compose path does not select standard mode'
if rg -Fq \
  'docker compose --env-file docker-compose/.env -f docker-compose/compose.yaml up -d' \
  "$repo_root/readme.md"; then
  fail 'the README bypasses installer-generated Compose secrets'
fi

if rg -ni 'wizard (creates|will create).*(Auth0|Keycloak).*(client|application)' \
  "$repo_root/readme.md" "$repo_root/docs"; then
  fail 'documentation incorrectly claims the wizard creates identity-provider clients.'
fi

rg -Fq 'Direct values take precedence' "$repo_root/docs" ||
  fail 'secret direct-variable precedence is undocumented.'
rg -Fq 'immutable' "$repo_root/docs/upgrades.md" ||
  fail 'semantic tag immutability is undocumented.'

printf 'documentation tests passed\n'

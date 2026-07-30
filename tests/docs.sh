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

for contract in \
  'novesGateway.existingSecret' \
  '.secrets/noves-gateway-auth-token' \
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
docs/security.md|routing.backend.enabled
EOF

if rg -ni 'Capture only|Redact' "$repo_root/docs/authentication"; then
  fail 'authentication guides expose screenshot-production instructions.'
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

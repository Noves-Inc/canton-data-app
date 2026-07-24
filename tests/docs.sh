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

while IFS= read -r slot; do
  grep -Fq -- "id: $slot" "$repo_root/docs/screenshots/manifest.yaml" ||
    fail "screenshot slot is missing from manifest: $slot"
done < <(
  rg -o 'Screenshot slot `[^`]+`' "$repo_root/docs/authentication" |
    sed -E 's/.*`([^`]+)`.*/\1/' |
    sort -u
)

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
  '/dev/tty' \
  'session-token' \
  'release-manifest.json' \
  'DATABASE_MAX_PARALLEL_WORKERS_PER_GATHER' \
  'READ_MODEL_TOTAL_CAPACITY'
do
  rg -Fq "$contract" "$repo_root/readme.md" "$repo_root/docs" ||
    fail "operator documentation is missing: $contract"
done

rg -Fq 'Direct values take precedence' "$repo_root/docs" ||
  fail 'secret direct-variable precedence is undocumented.'
rg -Fq 'immutable' "$repo_root/docs/upgrades.md" ||
  fail 'semantic tag immutability is undocumented.'

printf 'documentation tests passed\n'

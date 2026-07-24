#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/test.yml"
chart="$repo_root/chart/noves-canton-data-app/Chart.yaml"

fail() {
  printf 'release workflow test failed: %s\n' "$*" >&2
  exit 1
}

for repository in \
  noves-canton-backend-v4 \
  noves-canton-frontend-v4 \
  noves-canton-database-v4
do
  grep -Fq "$repository" "$workflow" ||
    fail "workflow does not resolve $repository"
done

for contract in \
  'docker/setup-buildx-action' \
  'docker buildx imagetools inspect' \
  'org.opencontainers.image.source' \
  'org.opencontainers.image.revision' \
  'org.opencontainers.image.version' \
  'scripts/create-release-manifest.sh' \
  'release-manifest.json' \
  'actions/upload-artifact' \
  'actions/attest-build-provenance@v3' \
  'attestations: write' \
  'id-token: write' \
  'contents: write' \
  'gh release create' \
  'SHA256SUMS' \
  'helm show chart' \
  'Refusing duplicate release'
do
  grep -Fq "$contract" "$workflow" ||
    fail "workflow is missing: $contract"
done

if grep -Fiq 'classifier' "$workflow"; then
  fail 'public release workflow exposes classifier identity'
fi

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
export RELEASE_VERSION=4.0.0
export CHART_SOURCE_REPOSITORY=https://github.com/Noves-Inc/canton-data-app
export CHART_SOURCE_COMMIT=4444444444444444444444444444444444444444
export BACKEND_REPOSITORY=ghcr.io/noves-inc/noves-canton-backend-v4
export BACKEND_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
export BACKEND_SOURCE_REPOSITORY=https://github.com/Noves-Inc/cda-backend
export BACKEND_SOURCE_COMMIT=1111111111111111111111111111111111111111
export FRONTEND_REPOSITORY=ghcr.io/noves-inc/noves-canton-frontend-v4
export FRONTEND_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
export FRONTEND_SOURCE_REPOSITORY=https://github.com/Noves-Inc/cda-frontend
export FRONTEND_SOURCE_COMMIT=2222222222222222222222222222222222222222
export DATABASE_REPOSITORY=ghcr.io/noves-inc/noves-canton-database-v4
export DATABASE_DIGEST="sha256:$(printf 'c%.0s' {1..64})"
export DATABASE_SOURCE_REPOSITORY=https://github.com/Noves-Inc/cda-db
export DATABASE_SOURCE_COMMIT=3333333333333333333333333333333333333333
"$repo_root/scripts/create-release-manifest.sh" "$manifest"

jq -e '
  .chart.version == "4.0.0" and
  .images.backend.source.commit == "1111111111111111111111111111111111111111" and
  .images.frontend.source.commit == "2222222222222222222222222222222222222222" and
  .images.database.source.commit == "3333333333333333333333333333333333333333" and
  ([paths | map(tostring) | join(".")] | all(test("classifier"; "i") | not))
' "$manifest" >/dev/null || fail 'generated manifest violates its public contract'

schema="$repo_root/release/release-manifest.schema.json"
jq -e '
  .additionalProperties == false and
  .properties.chart.additionalProperties == false and
  .properties.images.additionalProperties == false and
  .["$defs"].source.additionalProperties == false and
  .["$defs"].image.additionalProperties == false
' "$schema" >/dev/null || fail 'release manifest schema is not closed'

printf 'release workflow tests passed\n'

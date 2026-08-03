#!/usr/bin/env bash
set -euo pipefail

output="${1:?usage: scripts/create-release-manifest.sh OUTPUT}"

required=(
  RELEASE_VERSION
  CHART_SOURCE_REPOSITORY CHART_SOURCE_COMMIT
  BACKEND_REPOSITORY BACKEND_DIGEST BACKEND_SOURCE_REPOSITORY BACKEND_SOURCE_COMMIT
  FRONTEND_REPOSITORY FRONTEND_DIGEST FRONTEND_SOURCE_REPOSITORY FRONTEND_SOURCE_COMMIT
  DATABASE_REPOSITORY DATABASE_DIGEST DATABASE_SOURCE_REPOSITORY DATABASE_SOURCE_COMMIT
)
for name in "${required[@]}"; do
  [[ -n "${!name:-}" ]] ||
    { printf 'Missing release input: %s\n' "$name" >&2; exit 1; }
done

jq -n \
  --arg version "$RELEASE_VERSION" \
  --arg chartRepo "$CHART_SOURCE_REPOSITORY" \
  --arg chartCommit "$CHART_SOURCE_COMMIT" \
  --arg backendRepo "$BACKEND_REPOSITORY" \
  --arg backendDigest "$BACKEND_DIGEST" \
  --arg backendSourceRepo "$BACKEND_SOURCE_REPOSITORY" \
  --arg backendSourceCommit "$BACKEND_SOURCE_COMMIT" \
  --arg frontendRepo "$FRONTEND_REPOSITORY" \
  --arg frontendDigest "$FRONTEND_DIGEST" \
  --arg frontendSourceRepo "$FRONTEND_SOURCE_REPOSITORY" \
  --arg frontendSourceCommit "$FRONTEND_SOURCE_COMMIT" \
  --arg databaseRepo "$DATABASE_REPOSITORY" \
  --arg databaseDigest "$DATABASE_DIGEST" \
  --arg databaseSourceRepo "$DATABASE_SOURCE_REPOSITORY" \
  --arg databaseSourceCommit "$DATABASE_SOURCE_COMMIT" \
  '{
    chart: {
      version: $version,
      source: {repository: $chartRepo, commit: $chartCommit}
    },
    images: {
      backend: {
        repository: $backendRepo, tag: $version, digest: $backendDigest,
        source: {repository: $backendSourceRepo, commit: $backendSourceCommit}
      },
      frontend: {
        repository: $frontendRepo, tag: $version, digest: $frontendDigest,
        source: {repository: $frontendSourceRepo, commit: $frontendSourceCommit}
      },
      database: {
        repository: $databaseRepo, tag: $version, digest: $databaseDigest,
        source: {repository: $databaseSourceRepo, commit: $databaseSourceCommit}
      }
    }
  }' >"$output"

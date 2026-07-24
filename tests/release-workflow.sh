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
  'release-manifest.json' \
  'actions/upload-artifact' \
  'helm show chart' \
  'Refusing to replace existing chart version'
do
  grep -Fq "$contract" "$workflow" ||
    fail "workflow is missing: $contract"
done

printf 'release workflow tests passed\n'

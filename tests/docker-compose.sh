#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_dir="$repo_root/docker-compose"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() {
  printf 'docker-compose test failed: %s\n' "$*" >&2
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

docker compose --env-file "$compose_dir/.env.example" \
  -f "$compose_dir/compose.yaml" config >"$scratch/standard.yaml"
docker compose --env-file "$compose_dir/.env.example" \
  -f "$compose_dir/compose.setup.yaml" config >"$scratch/setup.yaml"
CDA_DATABASE_VOLUME=cda-v3-data \
CDA_MIGRATION_SOURCE_VERSION=3.16.1 \
CDA_MIGRATION_BACKUP_CONFIRMED=true \
CDA_MIGRATION_OLD_WORKLOAD_STOPPED=true \
docker compose --env-file "$compose_dir/.env.example" \
  -f "$compose_dir/compose.yaml" \
  -f "$compose_dir/compose.migrate-v3.yaml" config >"$scratch/migration.yaml"

for image in backend frontend database; do
  assert_contains "$scratch/standard.yaml" "noves-canton-${image}-v4:4.0.0"
done
assert_contains "$scratch/standard.yaml" 'container_name: noves-canton-backend-v4'
assert_contains "$scratch/standard.yaml" 'container_name: noves-canton-frontend-v4'
assert_contains "$scratch/standard.yaml" 'container_name: noves-canton-database-v4'
assert_contains "$scratch/standard.yaml" 'name: splice-validator_splice_validator'
assert_contains "$scratch/standard.yaml" 'SCAN_PROXY_URL: http://validator-app:5003'
assert_contains "$scratch/standard.yaml" 'target: /exports'
assert_contains "$compose_dir/config/nodes-config.json" 'participant:5001'
assert_not_contains "$scratch/standard.yaml" 'externalDatabase'

assert_contains "$scratch/setup.yaml" 'host_ip: 127.0.0.1'
assert_contains "$scratch/setup.yaml" 'published: "8099"'
assert_contains "$scratch/setup.yaml" 'start:setup'
assert_contains "$scratch/setup.yaml" 'SETUP_STORAGE_MODE: file'
assert_contains "$scratch/setup.yaml" 'user: 1000:1000'
assert_not_contains "$scratch/setup.yaml" '/var/run/docker.sock'
assert_not_contains "$scratch/setup.yaml" 'M2M_CLIENT_SECRET'

assert_contains "$scratch/migration.yaml" 'name: cda-v3-data'
assert_contains "$scratch/migration.yaml" 'CDA_SETUP_WIZARD_ENABLED: "false"'
assert_contains "$scratch/migration.yaml" 'CDA_MIGRATION_SOURCE_VERSION: 3.16.1'
assert_contains "$scratch/migration.yaml" 'CDA_MIGRATION_BACKUP_CONFIRMED: "true"'
assert_contains "$scratch/migration.yaml" 'CDA_MIGRATION_OLD_WORKLOAD_STOPPED: "true"'
assert_not_contains "$scratch/migration.yaml" 'kind: Job'

assert_contains "$compose_dir/.env.example" 'CDA_VERSION=4.0.0'
assert_not_contains "$compose_dir/.env.example" 'CDA_VERSION=latest'

printf 'docker compose tests passed\n'

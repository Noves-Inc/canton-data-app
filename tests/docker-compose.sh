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
SETUP_TOKEN=test-setup-token \
SETUP_SESSION_TOKEN=test-session-token \
SETUP_USER=1000:1000 \
docker compose --env-file "$compose_dir/.env.example" \
  -f "$compose_dir/compose.setup.yaml" config >"$scratch/setup.yaml"
DATABASE_VOLUME=cda-v3-data \
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
assert_contains "$scratch/standard.yaml" 'DATABASE_MAX_PARALLEL_WORKERS_PER_GATHER: "0"'
assert_contains "$scratch/standard.yaml" 'DATABASE_SYNCHRONOUS_COMMIT: "off"'
assert_contains "$scratch/standard.yaml" 'DATABASE_MAX_WAL_SIZE: 8GB'
assert_contains "$scratch/standard.yaml" 'INDEX_DB_WRITE_BATCH_SIZE: "250"'
assert_contains "$scratch/standard.yaml" 'READ_MODEL_TOTAL_CAPACITY: "4"'
assert_contains "$scratch/standard.yaml" 'READ_MODEL_BOOTSTRAP_BATCH_SIZE: "25"'
assert_contains "$scratch/standard.yaml" 'BACKGROUND_INDEXING_DUTY_PERCENT: "100"'
assert_contains "$scratch/standard.yaml" 'STREAM_POLL_INTERVAL_MS: "5000"'
assert_contains "$scratch/standard.yaml" 'STREAM_PAGE_SIZE: "100"'
assert_contains "$scratch/standard.yaml" 'STREAM_RETRY_DELAY_MS: "2000"'
assert_contains "$scratch/standard.yaml" 'STREAM_WEBSOCKET_BUFFER_LIMIT: "10000"'
assert_contains "$scratch/standard.yaml" 'STREAM_DATABASE_TIMEOUT_SECONDS: "60"'
assert_contains "$scratch/standard.yaml" 'STREAM_DEDUPLICATION_WINDOW_RECORDS: "1000000"'
assert_contains "$scratch/standard.yaml" 'STREAM_DELIVERY_RECENCY_MINUTES: "1440"'
assert_contains "$scratch/standard.yaml" 'ALLOW_PRIVATE_WEBHOOK_TARGETS: "false"'
assert_not_contains "$scratch/standard.yaml" 'CANTON_STREAM_URL'
assert_contains "$scratch/standard.yaml" 'target: /exports'
assert_contains "$compose_dir/config/nodes-config.json" 'participant:5001'
assert_not_contains "$scratch/standard.yaml" 'externalDatabase'
[[ "$(grep -c 'NOVES_GATEWAY_AUTH_TOKEN_FILE: /run/secrets/noves-gateway-auth-token' "$scratch/standard.yaml")" == 2 ]] ||
  fail 'gateway credential file must be configured for backend and frontend'
[[ "$(grep -c 'target: /run/secrets/noves-gateway-auth-token' "$scratch/standard.yaml")" == 2 ]] ||
  fail 'gateway credential must be mounted into backend and frontend'

assert_contains "$scratch/setup.yaml" 'host_ip: 127.0.0.1'
assert_contains "$scratch/setup.yaml" 'published: "8099"'
assert_contains "$scratch/setup.yaml" 'command:'
assert_contains "$scratch/setup.yaml" '- node'
assert_contains "$scratch/setup.yaml" '- runtime/setup.mjs'
assert_not_contains "$scratch/setup.yaml" 'start:setup'
assert_contains "$scratch/setup.yaml" 'SETUP_STORAGE_MODE: file'
assert_contains "$scratch/setup.yaml" 'user: 1000:1000'
assert_not_contains "$scratch/setup.yaml" '/var/run/docker.sock'
assert_not_contains "$scratch/setup.yaml" 'M2M_CLIENT_SECRET'
assert_contains "$scratch/setup.yaml" 'NOVES_GATEWAY_AUTH_TOKEN_FILE: /run/secrets/noves-gateway-auth-token'

assert_contains "$scratch/migration.yaml" 'name: cda-v3-data'
assert_contains "$scratch/migration.yaml" 'SETUP_ENABLED: "false"'
assert_not_contains "$scratch/migration.yaml" 'MIGRATION_SOURCE_VERSION'
assert_not_contains "$scratch/migration.yaml" 'MIGRATION_BACKUP_CONFIRMED'
assert_not_contains "$scratch/migration.yaml" 'MIGRATION_OLD_WORKLOAD_STOPPED'
assert_not_contains "$scratch/migration.yaml" 'kind: Job'

assert_contains "$compose_dir/.env.example" 'IMAGE_VERSION=4.0.0'
assert_not_contains "$compose_dir/.env.example" 'IMAGE_VERSION=latest'
assert_not_contains "$compose_dir/.env.example" 'CANTON_STREAM_URL'

printf 'docker compose tests passed\n'

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

install_dir="$PWD/noves-canton-data-app-v4"

usage() {
  cat <<'EOF'
Usage:
  install-compose.sh [--directory DIR]

Options:
  --directory DIR   Installation directory
EOF
}

while (($#)); do
  case "$1" in
    --directory) install_dir="${2:?Missing directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 or newer is required."
require_command openssl
require_command curl

mkdir -p "$install_dir/docker-compose/config"
for file in compose.yaml compose.migrate-v3.yaml .env.example; do
  cp "$repo_root/docker-compose/$file" "$install_dir/docker-compose/$file"
done
cp "$repo_root/docker-compose/config/storage.env.example" \
  "$install_dir/docker-compose/config/storage.env.example"
mkdir -p "$install_dir/docker-compose/.state" "$install_dir/docker-compose/.secrets"
if [[ ! -f "$install_dir/docker-compose/.state/nodes-config.json" ]]; then
  cp "$repo_root/docker-compose/config/nodes-config.json" \
    "$install_dir/docker-compose/.state/nodes-config.json"
fi

cd "$install_dir/docker-compose"
gateway_env_file=".state/gateway.env"
legacy_gateway_secret_file=".secrets/noves-gateway-auth-token"
if [[ -f "$gateway_env_file" ]]; then
  gateway_key_count="$(grep -c '^NOVES_GATEWAY_AUTH_TOKEN=' "$gateway_env_file" || true)"
  [[ "$gateway_key_count" == 1 ]] ||
    die "$gateway_env_file must contain exactly one NOVES_GATEWAY_AUTH_TOKEN."
  gateway_token="$(sed -n 's/^NOVES_GATEWAY_AUTH_TOKEN=//p' "$gateway_env_file")"
  [[ "$gateway_token" =~ [^[:space:]] ]] ||
    die "The existing Noves gateway credential is blank: $gateway_env_file"
elif [[ -f "$legacy_gateway_secret_file" ]]; then
  gateway_token="$(<"$legacy_gateway_secret_file")"
  [[ "$gateway_token" =~ [^[:space:]] ]] ||
    die "The existing Noves gateway credential file is blank: $legacy_gateway_secret_file"
else
  gateway_token="$(resolve_noves_gateway_token)"
fi
write_private_file "$gateway_env_file"
printf 'NOVES_GATEWAY_AUTH_TOKEN=%s\n' "$gateway_token" >"$gateway_env_file"
chmod 600 "$gateway_env_file"

accounting_env_file=".state/accounting.env"
if [[ ! -f "$accounting_env_file" ]]; then
  write_private_file "$accounting_env_file"
  printf 'ACCOUNTING_TOKEN_ENCRYPTION_KEY=%s\n' \
    "$(openssl rand -base64 32 | tr -d '\n')" >"$accounting_env_file"
fi
accounting_key_count="$(grep -c '^ACCOUNTING_TOKEN_ENCRYPTION_KEY=' "$accounting_env_file" || true)"
[[ "$accounting_key_count" == 1 ]] ||
  die "$accounting_env_file must contain exactly one ACCOUNTING_TOKEN_ENCRYPTION_KEY."
accounting_key="$(sed -n 's/^ACCOUNTING_TOKEN_ENCRYPTION_KEY=//p' "$accounting_env_file")"
[[ "$accounting_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
  die "$accounting_env_file must contain a 32-byte base64 ACCOUNTING_TOKEN_ENCRYPTION_KEY."
chmod 600 "$accounting_env_file"

ensure_env_secret() {
  local key="$1"
  local value
  value="$(sed -n "s/^${key}=//p" .env | tail -1)"
  if [[ -z "$value" || "$value" == replace-with-* ]]; then
    value="$(random_secret)"
    if grep -q "^${key}=" .env; then
      sed -i.bak -e "s/^${key}=.*/${key}=${value}/" .env
      rm -f .env.bak
    else
      printf '%s=%s\n' "$key" "$value" >>.env
    fi
  fi
  printf '%s' "$value"
}

env_value() {
  sed -n "s/^${1}=//p" .env | tail -1
}

validate_capture_env() {
  local file=".state/capture.env"
  local key
  for key in M2M_TOKEN_ENDPOINT M2M_CLIENT_ID M2M_CLIENT_SECRET M2M_AUDIENCE; do
    if ! grep -Eq "^${key}=(\"[^\"]+\"|[^[:space:]].*)$" "$file" ||
      grep -Eq "^${key}=\"?replace-with-" "$file"; then
      die "$file must contain a non-blank, non-placeholder $key."
    fi
  done
}

wait_for_backend_ready() {
  local origin="$1"
  local attempt
  for attempt in $(seq 1 120); do
    if curl -fsS "$origin/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  printf 'Last backend startup status:\n' >&2
  curl -sS "$origin/startupStatus" >&2 || true
  printf '\n' >&2
  return 1
}

[[ -f .env ]] || die "Create .env from .env.example before installation."
[[ -f .state/capture.env ]] || die "Create .state/capture.env with dedicated M2M credentials."
[[ -f .state/nodes-config.json ]] ||
  die "Create .state/nodes-config.json with the exact participant ID."
ensure_env_secret DATABASE_PASSWORD >/dev/null
if grep -Fq 'REPLACE_WITH_PARTICIPANT_ID' .state/nodes-config.json; then
  die "Replace REPLACE_WITH_PARTICIPANT_ID in .state/nodes-config.json."
fi
validate_capture_env
canton_network="$(env_value CANTON_NETWORK)"
case "$canton_network" in
  mainnet|testnet|devnet) ;;
  *) die "Set CANTON_NETWORK to mainnet, testnet, or devnet in .env." ;;
esac
canton_docker_network="$(env_value CANTON_DOCKER_NETWORK)"
canton_docker_network="${canton_docker_network:-splice-validator_splice_validator}"
chmod 600 .env .state/capture.env "$gateway_env_file" "$accounting_env_file"
chmod 644 .state/nodes-config.json
docker compose --env-file .env -f compose.yaml config --quiet ||
  die "The Compose application configuration is invalid."
docker network inspect "$canton_docker_network" >/dev/null 2>&1 ||
  die "Docker network '$canton_docker_network' does not exist."
participant_container="$(
  docker ps \
    --filter label=com.docker.compose.service=participant \
    --filter network="$canton_docker_network" \
    --format '{{.Names}}' |
    head -1
)"
[[ -n "$participant_container" ]] ||
  die "No running participant service is attached to '$canton_docker_network'."
validator_service_container="$(
  docker ps \
    --filter label=com.docker.compose.service=validator \
    --filter network="$canton_docker_network" \
    --format '{{.Names}}' |
    head -1
)"
[[ -n "$validator_service_container" ]] ||
  die "No running validator service is attached to '$canton_docker_network'."
docker compose --env-file .env -f compose.yaml pull ||
  die "Could not pull the Noves Data App images. Log in to the configured registries and retry."
docker compose --env-file .env -f compose.yaml up -d
backend_port="$(env_value BACKEND_PORT)"
backend_port="${backend_port:-8090}"
backend_origin="http://127.0.0.1:$backend_port"
wait_for_backend_ready "$backend_origin" ||
  die "The Noves Data App did not become ready. Run: docker compose --env-file .env -f compose.yaml logs backend"
printf 'Installation complete. Backend status: %s/startupStatus\n' "$backend_origin"

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/setup-admin.sh
source "$script_dir/lib/setup-admin.sh"

install_dir="$PWD/noves-canton-data-app-v4"
mode=guided
validator_container=""

usage() {
  cat <<'EOF'
Usage:
  install-compose.sh                       Guided localhost setup
  install-compose.sh --standard

Options:
  --directory DIR   Installation directory
  --validator-container NAME
                    Running validator container when more than one is detected
  --standard        Start from existing .env, .state/capture.env, and nodes config
EOF
}

while (($#)); do
  case "$1" in
    --directory) install_dir="${2:?Missing directory}"; shift 2 ;;
    --validator-container)
      validator_container="${2:?Missing container name}"
      shift 2
      ;;
    --standard) mode=standard; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 or newer is required."
require_command openssl
require_command curl

mkdir -p "$install_dir/docker-compose/config"
for file in compose.yaml compose.setup.yaml compose.migrate-v3.yaml .env.example; do
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

if [[ "$mode" == standard ]]; then
  [[ -f .env ]] || die "Create .env from .env.example before a standard install."
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
    die "Could not pull the Noves App images. Log in to the configured registries and retry."
  docker compose --env-file .env -f compose.yaml up -d
  backend_port="$(env_value BACKEND_PORT)"
  backend_port="${backend_port:-8090}"
  backend_origin="http://127.0.0.1:$backend_port"
  wait_for_backend_ready "$backend_origin" ||
    die "The Noves App did not become ready. Run: docker compose --env-file .env -f compose.yaml logs backend"
  printf 'Installation complete. Backend status: %s/startupStatus\n' "$backend_origin"
  exit 0
fi

require_command jq

if [[ ! -f .env ]]; then
  database_password="$(random_secret)"
  setup_token="$(random_secret)"
  setup_session_token="$(random_secret)"
  umask 077
  sed \
    -e "s/^DATABASE_PASSWORD=.*/DATABASE_PASSWORD=$database_password/" \
    .env.example >.env
  chmod 600 .env
fi

setup_token="$(ensure_env_secret SETUP_TOKEN)"
setup_session_token="$(ensure_env_secret SETUP_SESSION_TOKEN)"

setup_user="$(id -u):$(id -g)"
if grep -q '^SETUP_USER=' .env; then
  sed -i.bak -e "s/^SETUP_USER=.*/SETUP_USER=$setup_user/" .env
  rm -f .env.bak
else
  printf 'SETUP_USER=%s\n' "$setup_user" >>.env
fi
chmod 600 .env

docker compose --env-file .env -f compose.setup.yaml up -d
setup_port="$(sed -n 's/^SETUP_PORT=//p' .env | tail -1)"
setup_port="${setup_port:-8099}"
setup_origin="http://127.0.0.1:$setup_port"
canton_docker_network="$(sed -n 's/^CANTON_DOCKER_NETWORK=//p' .env | tail -1)"
canton_docker_network="${canton_docker_network:-splice-validator_splice_validator}"
wait_for_setup_health "$setup_origin" ||
  die "The localhost setup service did not become ready."
if ! bootstrap_compose_setup_admin \
  "$validator_container" \
  "$canton_docker_network" \
  "$setup_origin" \
  "$setup_token"; then
  printf '%s\n' \
    'Warning: validator administrator discovery failed; the wizard will show manual participant commands.' >&2
fi
setup_url="http://127.0.0.1:$setup_port/#session=$setup_session_token"
printf 'Setup is ready at %s\n' "$setup_url"
open_browser "$setup_url"
printf 'Waiting for you to finish the setup wizard. Press Ctrl-C to stop safely.\n'

while true; do
  if [[ -f .state/values.json ]] && jq -e '.completed == true' .state/values.json >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

validate_capture_env

app_url="$(jq -r '.appUrl' .state/values.json)"
provider="$(jq -r '.provider' .state/values.json)"
node_id="$(jq -r '.nodeId' .state/values.json)"
participant_address="$(jq -r '.participantAddress' .state/values.json)"
expected_participant_id="$(jq -r '.expectedParticipantId' .state/values.json)"
expected_network="$(jq -r '.expectedNetwork' .state/values.json)"
validator_url="$(jq -r '.validatorUrl' .state/values.json)"
public_scan_url="$(jq -r '.publicScanUrl // ""' .state/values.json)"
jq -n \
  --arg nodeId "$node_id" \
  --arg participantAddress "$participant_address" \
  --arg expectedParticipantId "$expected_participant_id" \
  '{
    primaryNodeId: $nodeId,
    nodes: {
      ($nodeId): {
        addr: $participantAddress,
        expectedParticipantId: $expectedParticipantId,
        validator_party: "",
        synchronizer_alias: "global",
        expected_synchronizer_id: ""
      }
    }
  }' >.state/nodes-config.json

sed -i.bak \
  -e "s|^APP_URL=.*|APP_URL=$app_url|" \
  -e "s|^CANTON_NETWORK=.*|CANTON_NETWORK=$expected_network|" \
  -e "s|^CANTON_VALIDATOR_URL=.*|CANTON_VALIDATOR_URL=$validator_url|" \
  -e "s|^CANTON_PUBLIC_SCAN_URL=.*|CANTON_PUBLIC_SCAN_URL=$public_scan_url|" \
  .env
rm -f .env.bak

if [[ "$provider" == auth0 ]]; then
  auth0_domain="$(jq -r '.auth0Domain' .state/values.json)"
  browser_client_id="$(jq -r '.browserClientId' .state/values.json)"
  browser_audience="$(jq -r '.browserAudience' .state/values.json)"
  sed -i.bak \
    -e "s|^APP_URL=.*|APP_URL=$app_url|" \
    -e "s|^VITE_AUTH0_DOMAIN=.*|VITE_AUTH0_DOMAIN=$auth0_domain|" \
    -e "s|^VITE_AUTH0_CLIENT_ID=.*|VITE_AUTH0_CLIENT_ID=$browser_client_id|" \
    -e "s|^VITE_AUTH0_AUDIENCE=.*|VITE_AUTH0_AUDIENCE=$browser_audience|" \
    .env
else
  keycloak_url="$(jq -r '.keycloakUrl' .state/values.json)"
  keycloak_realm="$(jq -r '.keycloakRealm' .state/values.json)"
  browser_client_id="$(jq -r '.browserClientId' .state/values.json)"
  sed -i.bak \
    -e "s|^APP_URL=.*|APP_URL=$app_url|" \
    -e "s|^VITE_AUTH0_DOMAIN=.*|VITE_AUTH0_DOMAIN=|" \
    -e "s|^VITE_KEYCLOAK_URL=.*|VITE_KEYCLOAK_URL=$keycloak_url|" \
    -e "s|^VITE_KEYCLOAK_REALM=.*|VITE_KEYCLOAK_REALM=$keycloak_realm|" \
    -e "s|^VITE_KEYCLOAK_CLIENT_ID=.*|VITE_KEYCLOAK_CLIENT_ID=$browser_client_id|" \
    .env
fi
rm -f .env.bak
chmod 600 .env .state/capture.env "$gateway_env_file" .state/values.json
chmod 644 .state/nodes-config.json

docker compose --env-file .env -f compose.setup.yaml down
docker compose --env-file .env -f compose.yaml up -d --wait
printf 'Installation complete. Open %s\n' "$app_url"

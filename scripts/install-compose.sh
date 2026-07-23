#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

install_dir="${CDA_INSTALL_DIR:-$PWD/noves-canton-data-app-v4}"
mode=guided

usage() {
  cat <<'EOF'
Usage:
  install-compose.sh                       Guided localhost setup
  install-compose.sh --standard

Options:
  --directory DIR   Installation directory
  --standard        Start from existing .env, .state/capture.env, and nodes config
EOF
}

while (($#)); do
  case "$1" in
    --directory) install_dir="${2:?Missing directory}"; shift 2 ;;
    --standard) mode=standard; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_command docker
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 or newer is required."

mkdir -p "$install_dir/docker-compose"
for file in compose.yaml compose.setup.yaml compose.migrate-v3.yaml .env.example; do
  cp "$repo_root/docker-compose/$file" "$install_dir/docker-compose/$file"
done
mkdir -p "$install_dir/docker-compose/.state"
if [[ ! -f "$install_dir/docker-compose/.state/nodes-config.json" ]]; then
  cp "$repo_root/docker-compose/config/nodes-config.json" \
    "$install_dir/docker-compose/.state/nodes-config.json"
fi

cd "$install_dir/docker-compose"
if [[ "$mode" == standard ]]; then
  [[ -f .env ]] || die "Create .env from .env.example before a standard install."
  [[ -f .state/capture.env ]] || die "Create .state/capture.env with dedicated M2M credentials."
  chmod 600 .env .state/capture.env
  exec docker compose --env-file .env -f compose.yaml up -d
fi

require_command jq
require_command openssl

if [[ ! -f .env ]]; then
  database_password="$(random_secret)"
  setup_token="$(random_secret)"
  umask 077
  sed \
    -e "s/^CDA_DATABASE_PASSWORD=.*/CDA_DATABASE_PASSWORD=$database_password/" \
    -e "s/^CDA_SETUP_TOKEN=.*/CDA_SETUP_TOKEN=$setup_token/" \
    .env.example >.env
  chmod 600 .env
fi

setup_uid="$(id -u)"
setup_gid="$(id -g)"
for assignment in "CDA_SETUP_UID=$setup_uid" "CDA_SETUP_GID=$setup_gid"; do
  key="${assignment%%=*}"
  if grep -q "^${key}=" .env; then
    sed -i.bak -e "s/^${key}=.*/${assignment}/" .env
    rm -f .env.bak
  else
    printf '%s\n' "$assignment" >>.env
  fi
done
chmod 600 .env

docker compose --env-file .env -f compose.setup.yaml up -d
setup_port="$(sed -n 's/^CDA_SETUP_PORT=//p' .env | tail -1)"
setup_port="${setup_port:-8099}"
setup_url="http://127.0.0.1:$setup_port"
printf 'Setup is ready at %s\n' "$setup_url"
open_browser "$setup_url"
printf 'Waiting for you to finish the setup wizard. Press Ctrl-C to stop safely.\n'

while true; do
  if [[ -f .state/values.json ]] && jq -e '.completed == true' .state/values.json >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

for key in M2M_TOKEN_ENDPOINT M2M_CLIENT_ID M2M_CLIENT_SECRET M2M_AUDIENCE; do
  if ! grep -Eq "^${key}=(\"[^\"]+\"|[^[:space:]].*)$" .state/capture.env; then
    die "The dedicated capture credential file is incomplete; rerun the wizard."
  fi
done

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
  -e "s|^CDA_APP_URL=.*|CDA_APP_URL=$app_url|" \
  -e "s|^CDA_NETWORK=.*|CDA_NETWORK=$expected_network|" \
  -e "s|^CDA_VALIDATOR_URL=.*|CDA_VALIDATOR_URL=$validator_url|" \
  -e "s|^CDA_PUBLIC_SCAN_URL=.*|CDA_PUBLIC_SCAN_URL=$public_scan_url|" \
  .env
rm -f .env.bak

if [[ "$provider" == auth0 ]]; then
  auth0_domain="$(jq -r '.auth0Domain' .state/values.json)"
  browser_client_id="$(jq -r '.browserClientId' .state/values.json)"
  browser_audience="$(jq -r '.browserAudience' .state/values.json)"
  sed -i.bak \
    -e "s|^CDA_APP_URL=.*|CDA_APP_URL=$app_url|" \
    -e "s|^VITE_AUTH0_DOMAIN=.*|VITE_AUTH0_DOMAIN=$auth0_domain|" \
    -e "s|^VITE_AUTH0_CLIENT_ID=.*|VITE_AUTH0_CLIENT_ID=$browser_client_id|" \
    -e "s|^VITE_AUTH0_AUDIENCE=.*|VITE_AUTH0_AUDIENCE=$browser_audience|" \
    .env
else
  keycloak_url="$(jq -r '.keycloakUrl' .state/values.json)"
  keycloak_realm="$(jq -r '.keycloakRealm' .state/values.json)"
  browser_client_id="$(jq -r '.browserClientId' .state/values.json)"
  sed -i.bak \
    -e "s|^CDA_APP_URL=.*|CDA_APP_URL=$app_url|" \
    -e "s|^VITE_AUTH0_DOMAIN=.*|VITE_AUTH0_DOMAIN=|" \
    -e "s|^VITE_KEYCLOAK_URL=.*|VITE_KEYCLOAK_URL=$keycloak_url|" \
    -e "s|^VITE_KEYCLOAK_REALM=.*|VITE_KEYCLOAK_REALM=$keycloak_realm|" \
    -e "s|^VITE_KEYCLOAK_CLIENT_ID=.*|VITE_KEYCLOAK_CLIENT_ID=$browser_client_id|" \
    .env
fi
rm -f .env.bak
chmod 600 .env .state/capture.env .state/nodes-config.json .state/values.json

docker compose --env-file .env -f compose.setup.yaml down
docker compose --env-file .env -f compose.yaml up -d
printf 'Installation complete. Open %s\n' "$app_url"

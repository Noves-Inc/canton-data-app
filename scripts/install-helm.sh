#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

chart_ref="${CDA_CHART_REF:-oci://ghcr.io/noves-inc/charts/noves-canton-data-app}"
chart_constraint='>=4.0.0 <5.0.0'
namespace="${CDA_NAMESPACE:-validator}"
release="${CDA_RELEASE:-noves-canton-data-app}"
local_port="${CDA_SETUP_PORT:-8099}"
mode=guided
values_file=""

usage() {
  cat <<'EOF'
Usage:
  install-helm.sh                         Guided localhost setup
  install-helm.sh --standard --values FILE

Options:
  --namespace NAME   Kubernetes namespace (default: validator)
  --release NAME     Helm release name (default: noves-canton-data-app)
  --values FILE      Operator-maintained values file
  --standard         Skip the wizard and perform a conventional Helm install
EOF
}

while (($#)); do
  case "$1" in
    --namespace) namespace="${2:?Missing namespace}"; shift 2 ;;
    --release) release="${2:?Missing release}"; shift 2 ;;
    --values) values_file="${2:?Missing values file}"; shift 2 ;;
    --standard) mode=standard; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_command helm
require_command kubectl

if [[ "$mode" == standard ]]; then
  [[ -n "$values_file" ]] || die "--standard requires --values FILE."
  [[ -f "$values_file" ]] || die "Values file not found: $values_file"
  exec helm upgrade --install "$release" "$chart_ref" \
    --version "$chart_constraint" \
    --namespace "$namespace" \
    --create-namespace \
    --values "$values_file"
fi

require_command jq
require_command openssl

database_secret="${release}-database"
capture_secret="${release}-capture-auth"
setup_token_secret="${release}-setup-token"
result_configmap="${release}-setup-results"
database_password="$(random_secret)"
setup_token="$(random_secret)"
scratch="$(mktemp -d)"
port_forward_pid=""

cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" >/dev/null 2>&1 || true
    wait "$port_forward_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

kubectl create namespace "$namespace" --dry-run=client -o yaml |
  kubectl apply -f -
kubectl --namespace "$namespace" create secret generic "$database_secret" \
  --from-literal="POSTGRES_PASSWORD=$database_password" \
  --dry-run=client -o yaml |
  kubectl apply -f -
kubectl --namespace "$namespace" create secret generic "$capture_secret" \
  --from-literal="M2M_INDEXER_ENABLED=false" \
  --dry-run=client -o yaml |
  kubectl apply -f -
kubectl --namespace "$namespace" create secret generic "$setup_token_secret" \
  --from-literal="token=$setup_token" \
  --dry-run=client -o yaml |
  kubectl apply -f -

helm upgrade --install "$release" "$chart_ref" \
  --version "$chart_constraint" \
  --namespace "$namespace" \
  --set setupWizard.enabled=true \
  --set "setupWizard.setupTokenSecret=$setup_token_secret" \
  --set "database.existingSecret=$database_secret" \
  --set "capture.existingSecret=$capture_secret" \
  --wait

kubectl --namespace "$namespace" port-forward \
  "service/${release}-setup-wizard" "$local_port:3000" >"$scratch/port-forward.log" 2>&1 &
port_forward_pid=$!
setup_url="http://127.0.0.1:$local_port"
printf 'Setup is ready at %s\n' "$setup_url"
open_browser "$setup_url"

printf 'Waiting for you to finish the setup wizard. Press Ctrl-C to stop safely.\n'
while true; do
  result_json="$(
    kubectl --namespace "$namespace" get configmap "$result_configmap" \
      -o jsonpath='{.data.values\.json}' 2>/dev/null || true
  )"
  if [[ -n "$result_json" ]] && jq -e '.completed == true' >/dev/null 2>&1 <<<"$result_json"; then
    break
  fi
  if ! kill -0 "$port_forward_pid" >/dev/null 2>&1; then
    sed -n '1,120p' "$scratch/port-forward.log" >&2
    die "The localhost port-forward stopped before setup completed."
  fi
  sleep 2
done

app_url="$(jq -r '.appUrl' <<<"$result_json")"
route_host="${app_url#*://}"
route_host="${route_host%%/*}"
final_values="$scratch/final-values.json"
jq --arg databaseSecret "$database_secret" \
  --arg captureSecret "$capture_secret" \
  --arg routeHost "$route_host" \
  '{
    setupWizard: {enabled: false},
    database: {existingSecret: $databaseSecret},
    capture: {existingSecret: $captureSecret},
    canton: {
      nodeId: .nodeId,
      participantAddress: .participantAddress,
      expectedParticipantId: .expectedParticipantId,
      validatorUrl: .validatorUrl,
      network: .expectedNetwork
    },
    oidc: {
      provider: .provider,
      appUrl: .appUrl,
      auth0: {
        domain: (if .provider == "auth0" then .auth0Domain else "" end),
        clientId: (if .provider == "auth0" then .browserClientId else "" end),
        audience: (if .provider == "auth0" then .browserAudience else "" end)
      },
      keycloak: {
        url: (if .provider == "keycloak" then .keycloakUrl else "" end),
        realm: (if .provider == "keycloak" then .keycloakRealm else "canton" end),
        clientId: (if .provider == "keycloak" then .browserClientId else "" end)
      }
    },
    routing: {
      enabled: true,
      host: $routeHost,
      istio: {enabled: (.routingMode == "istio")},
      ingress: {enabled: (.routingMode == "ingress")}
    }
  }' <<<"$result_json" >"$final_values"

helm upgrade --install "$release" "$chart_ref" \
  --version "$chart_constraint" \
  --namespace "$namespace" \
  --values "$final_values" \
  --wait

kubectl --namespace "$namespace" delete secret "$setup_token_secret" --ignore-not-found
printf 'Installation complete. Open %s\n' "$app_url"

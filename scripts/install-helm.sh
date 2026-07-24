#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"
# shellcheck source=lib/setup-admin.sh
source "$script_dir/lib/setup-admin.sh"

chart_ref="oci://ghcr.io/noves-inc/charts/noves-canton-data-app"
chart_constraint='>=4.0.0 <5.0.0'
namespace="validator"
release="noves-canton-data-app"
local_port="8099"
mode=guided
values_file=""
participant_admin_secret="splice-app-validator-ledger-api-auth"

usage() {
  cat <<'EOF'
Usage:
  install-helm.sh                         Guided localhost setup
  install-helm.sh --standard --values FILE

Options:
  --namespace NAME   Kubernetes namespace (default: validator)
  --release NAME     Helm release name (default: noves-canton-data-app)
  --setup-port PORT  Local wizard port (default: 8099)
  --values FILE      Operator-maintained values file
  --participant-admin-secret NAME
                       Validator participant-admin Secret used transiently by guided setup
  --standard         Skip the wizard and perform a conventional Helm install
EOF
}

while (($#)); do
  case "$1" in
    --namespace) namespace="${2:?Missing namespace}"; shift 2 ;;
    --release) release="${2:?Missing release}"; shift 2 ;;
    --setup-port) local_port="${2:?Missing setup port}"; shift 2 ;;
    --values) values_file="${2:?Missing values file}"; shift 2 ;;
    --participant-admin-secret)
      participant_admin_secret="${2:?Missing Secret name}"
      shift 2
      ;;
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
require_command curl

database_secret="${release}-database"
capture_secret="${release}-capture-auth"
gateway_secret="${release}-gateway"
setup_token_secret="${release}-setup-token"
result_configmap="${release}-setup-results"
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
if ! kubectl --namespace "$namespace" get secret "$database_secret" >/dev/null 2>&1; then
  database_password="$(random_secret)"
  kubectl --namespace "$namespace" create secret generic "$database_secret" \
    --from-literal="postgres-password=$database_password"
fi
if ! kubectl --namespace "$namespace" get secret "$capture_secret" >/dev/null 2>&1; then
  kubectl --namespace "$namespace" create secret generic "$capture_secret" \
    --from-literal="ledger-api-user=" \
    --from-literal="token-endpoint=" \
    --from-literal="client-id=" \
    --from-literal="client-secret=" \
    --from-literal="audience=" \
    --from-literal="scope="
fi
if ! kubectl --namespace "$namespace" get secret "$gateway_secret" >/dev/null 2>&1; then
  noves_gateway_token="$(resolve_noves_gateway_token)"
  kubectl --namespace "$namespace" create secret generic "$gateway_secret" \
    --from-literal="token=$noves_gateway_token"
fi
if kubectl --namespace "$namespace" get secret "$setup_token_secret" >/dev/null 2>&1; then
  setup_token="$(
    kubectl --namespace "$namespace" get secret "$setup_token_secret" \
      -o jsonpath='{.data.token}' | base64 --decode
  )"
  setup_session_token="$(
    kubectl --namespace "$namespace" get secret "$setup_token_secret" \
      -o jsonpath='{.data.session-token}' | base64 --decode
  )"
else
  setup_token="$(random_secret)"
  setup_session_token="$(random_secret)"
fi
setup_token="${setup_token:-$(random_secret)}"
setup_session_token="${setup_session_token:-$(random_secret)}"
kubectl --namespace "$namespace" create secret generic "$setup_token_secret" \
  --from-literal="token=$setup_token" \
  --from-literal="session-token=$setup_session_token" \
  --dry-run=client -o yaml |
  kubectl --namespace "$namespace" apply -f -

result_json="$(
  kubectl --namespace "$namespace" get configmap "$result_configmap" \
    -o jsonpath='{.data.values\.json}' 2>/dev/null || true
)"

helm upgrade --install "$release" "$chart_ref" \
  --version "$chart_constraint" \
  --namespace "$namespace" \
  --set setupWizard.enabled=true \
  --set "setupWizard.setupTokenSecret=$setup_token_secret" \
  --set "novesGateway.existingSecret=$gateway_secret" \
  --set "database.existingSecret=$database_secret" \
  --set "capture.existingSecret=$capture_secret" \
  --wait

if [[ -z "$result_json" ]] || ! jq -e '.completed == true' >/dev/null 2>&1 <<<"$result_json"; then
  kubectl --namespace "$namespace" port-forward \
    "deployment/${release}-setup-wizard" "$local_port:3000" >"$scratch/port-forward.log" 2>&1 &
  port_forward_pid=$!
  setup_origin="http://127.0.0.1:$local_port"
  wait_for_setup_health "$setup_origin" ||
    die "The localhost setup service did not become ready."
  if ! bootstrap_helm_setup_admin \
    "$namespace" \
    "$participant_admin_secret" \
    "$setup_origin" \
    "$setup_token"; then
    printf '%s\n' \
      'Warning: validator administrator discovery failed; the wizard will show manual participant commands.' >&2
  fi
  setup_url="http://127.0.0.1:$local_port/#session=$setup_session_token"
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
else
  printf 'Resuming the completed setup result for release %s.\n' "$release"
fi

capture_json="$(
  kubectl --namespace "$namespace" get secret "$capture_secret" -o json
)" || die "Could not read the dedicated capture Secret."
if ! jq -e '
  . as $secret
  | ["ledger-api-user", "token-endpoint", "client-id", "client-secret", "audience"]
  | all(. as $key | (($secret.data[$key] // "") | length > 0))
' >/dev/null <<<"$capture_json"; then
  die "The dedicated capture Secret is incomplete; rerun the wizard before activation."
fi

app_url="$(jq -r '.appUrl' <<<"$result_json")"
route_host="$(jq -er '.routingHost' <<<"$result_json")"
final_values="$scratch/final-values.json"
jq --arg databaseSecret "$database_secret" \
  --arg captureSecret "$capture_secret" \
  --arg gatewaySecret "$gateway_secret" \
  --arg routeHost "$route_host" \
  '{
    setupWizard: {enabled: false},
    database: {existingSecret: $databaseSecret},
    capture: {existingSecret: $captureSecret},
    novesGateway: {existingSecret: $gatewaySecret},
    canton: {
      nodeId: .nodeId,
      participantAddress: .participantAddress,
      expectedParticipantId: .expectedParticipantId,
      validatorUrl: .validatorUrl,
      publicScanUrl: (.publicScanUrl // ""),
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

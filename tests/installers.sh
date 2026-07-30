#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"

fail() {
  printf 'installer test failed: %s\n' "$*" >&2
  exit 1
}

cat >"$fake_bin/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INSTALLER_CALLS"
if [[ -n "${FINAL_VALUES_CAPTURE:-}" ]]; then
  values_source=""
  while (($#)); do
    if [[ "$1" == "--values" && -f "${2:-}" ]]; then
      values_source="$2"
      shift
    fi
    shift
  done
  if [[ -n "$values_source" ]]; then
    cp "$values_source" "$FINAL_VALUES_CAPTURE"
  fi
fi
EOF
cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INSTALLER_CALLS"
if [[ "$*" == *"port-forward"* ]]; then
  while true; do sleep 1; done
elif [[ "$*" == *"get secret"*"splice-app-validator-ledger-api-auth"*"-o json"* ]] \
  || [[ "$*" == *"get secret"*"custom-admin-secret"*"-o json"* ]]; then
  printf '%s' '{"data":{"url":"aHR0cHM6Ly9zc28uZXhhbXBsZS5jb20vcmVhbG1zL2NhbnRvbi9wcm90b2NvbC9vcGVuaWQtY29ubmVjdC90b2tlbg==","ledger-api-user":"dmFsaWRhdG9yLWFkbWlu","client-id":"dmFsaWRhdG9yLWNsaWVudA==","client-secret":"dmFsaWRhdG9yLXNlY3JldA==","audience":"aHR0cHM6Ly9sZWRnZXItYXBp","scope":"ZGFtbF9sZWRnZXJfYXBp"}}'
elif [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get secret"*"setup-token"*"-o jsonpath={.data.token}"* ]]; then
  printf 'c2V0dXAtc2VjcmV0'
elif [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get secret"*"setup-token"*"-o jsonpath={.data.session-token}"* ]]; then
  printf 'YnJvd3Nlci1zZWNyZXQ='
elif { [[ -n "${GUIDED_RESULT:-}" ]] \
    || [[ -n "${ACTIVE_GUIDED_MARKER:-}" && -f "$ACTIVE_GUIDED_MARKER" ]]; } \
  && [[ "$*" == *"get secret"*"capture-auth"*"-o json"* ]]; then
  printf '%s' '{"data":{"ledger-api-user":"Y2FwdHVyZS11c2Vy","token-endpoint":"aHR0cHM6Ly9pc3N1ZXIuZXhhbXBsZS90b2tlbg==","client-id":"Y2FwdHVyZS1jbGllbnQ=","client-secret":"c2VjcmV0","audience":"aHR0cHM6Ly9sZWRnZXItYXBp","scope":""}}'
elif [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get configmap"*"setup-results"* ]]; then
  printf '%s' "$GUIDED_RESULT"
elif [[ -n "${ACTIVE_GUIDED_MARKER:-}" && -f "$ACTIVE_GUIDED_MARKER" ]] \
  && [[ "$*" == *"get configmap"*"setup-results"* ]]; then
  printf '%s' "$ACTIVE_GUIDED_RESULT"
fi
exit 0
EOF
cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "compose version" ]]; then
  exit 0
fi
printf '%s\n' "$*" >>"$INSTALLER_CALLS"
if [[ "$1" == network && "$2" == inspect ]]; then
  [[ -z "${DOCKER_NETWORK_MISSING:-}" ]]
elif [[ "$1" == ps && "$*" == *"com.docker.compose.service=participant"* ]]; then
  printf '%s\n' "${DOCKER_PARTICIPANT:-participant-one}"
elif [[ "$1" == ps && "$*" == *"com.docker.compose.service=validator"* ]]; then
  if [[ -n "${DOCKER_VALIDATORS+x}" ]]; then
    printf '%s\n' $DOCKER_VALIDATORS
  else
    printf '%s\n' validator-one
  fi
elif [[ "$1" == compose && "$*" == *" pull"* ]]; then
  [[ -z "${DOCKER_PULL_FAIL:-}" ]]
elif [[ "$1" == inspect ]]; then
  container_name="${2:-validator-one}"
  validator_label="${DOCKER_VALIDATOR_LABEL:-validator}"
  validator_running="${DOCKER_VALIDATOR_RUNNING:-true}"
  validator_network="${DOCKER_VALIDATOR_NETWORK:-splice-validator_splice_validator}"
  printf '[{"Name":"/%s","State":{"Running":%s},"Config":{"Labels":{"com.docker.compose.service":"%s"},"Env":["SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_URL=https://tenant.auth0.com/oauth/token","SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_CLIENT_ID=validator-client","SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_CLIENT_SECRET=validator-secret","SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_AUDIENCE=https://ledger-api","SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_SCOPE=daml_ledger_api","SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_USER_NAME=validator-admin"]},"NetworkSettings":{"Networks":{"%s":{}}}}]' \
    "$container_name" "$validator_running" "$validator_label" "$validator_network"
fi
EOF
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INSTALLER_CALLS"
if [[ "$*" == *"/ready"* ]]; then
  [[ -z "${BACKEND_READY_FAIL:-}" ]]
elif [[ "$*" == *"/startup-status"* ]]; then
  printf '%s' '{"phase":"ready","ready":true}'
elif [[ "$*" == *"--data-binary @-"* ]]; then
  payload="$(cat)"
  jq -e '
    .sourceMode as $mode
    | ($mode == "helm" or $mode == "compose")
    and .discoveryUrl == (if $mode == "helm"
      then "https://sso.example.com/realms/canton/protocol/openid-connect/token"
      else "https://tenant.auth0.com/oauth/token" end)
    and .expectedAdministratorUserId == "validator-admin"
    and .clientId == "validator-client"
    and .clientSecret == "validator-secret"
    and .audience == "https://ledger-api"
    and .scope == "daml_ledger_api"
    and (if $mode == "helm"
      then .participantNamespace == "validator"
      else (.validatorContainer | startswith("/validator"))
        and .composeNetwork == "splice-validator_splice_validator"
      end)
  ' >/dev/null <<<"$payload" || exit 41
  jq -r '[.sourceMode,.expectedAdministratorUserId] | @tsv' <<<"$payload" \
    >>"$BOOTSTRAP_CHECK"
  if [[ -n "${ACTIVE_GUIDED_MARKER:-}" ]]; then
    touch "$ACTIVE_GUIDED_MARKER"
  fi
  if [[ -n "${ACTIVE_COMPOSE_STATE_DIR:-}" ]]; then
    mkdir -p "$ACTIVE_COMPOSE_STATE_DIR"
    printf '%s' "$ACTIVE_COMPOSE_RESULT" \
      >"$ACTIVE_COMPOSE_STATE_DIR/values.json"
    printf '%s\n' \
      'M2M_INDEXER_ENABLED=true' \
      'M2M_LEDGER_API_USER=capture-user' \
      'M2M_TOKEN_ENDPOINT=https://issuer.example/token' \
      'M2M_CLIENT_ID=capture-client' \
      'M2M_CLIENT_SECRET=capture-secret' \
      'M2M_AUDIENCE=https://ledger-api' \
      'M2M_SCOPE=' \
      >"$ACTIVE_COMPOSE_STATE_DIR/capture.env"
    chmod 600 \
      "$ACTIVE_COMPOSE_STATE_DIR/values.json" \
      "$ACTIVE_COMPOSE_STATE_DIR/capture.env"
  fi
  printf '%s' '{"status":"stored"}'
fi
EOF
cat >"$fake_bin/open" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x \
  "$fake_bin/helm" \
  "$fake_bin/kubectl" \
  "$fake_bin/docker" \
  "$fake_bin/curl" \
  "$fake_bin/open"

gateway_file="$scratch/gateway-token"
printf 'file-token\n' >"$gateway_file"
resolved="$(
  NOVES_GATEWAY_AUTH_TOKEN=direct-token \
  NOVES_GATEWAY_AUTH_TOKEN_FILE="$scratch/missing" \
    bash -c 'source "$1"; resolve_noves_gateway_token' _ \
    "$repo_root/scripts/lib/common.sh"
)"
[[ "$resolved" == direct-token ]] ||
  fail 'direct gateway credential did not take precedence over the file source.'

resolved="$(
  NOVES_GATEWAY_AUTH_TOKEN_FILE="$gateway_file" \
    bash -c 'source "$1"; resolve_noves_gateway_token' _ \
    "$repo_root/scripts/lib/common.sh"
)"
[[ "$resolved" == file-token ]] ||
  fail 'gateway credential file was not read and trimmed.'

if NOVES_GATEWAY_AUTH_TOKEN_FILE="$scratch/missing" \
  bash -c 'source "$1"; resolve_noves_gateway_token' _ \
  "$repo_root/scripts/lib/common.sh" >"$scratch/missing-gateway.out" 2>&1; then
  fail 'an explicit missing gateway credential file was accepted.'
fi
grep -Fq 'NOVES_GATEWAY_AUTH_TOKEN_FILE' "$scratch/missing-gateway.out" ||
  fail 'missing gateway credential file error did not name the source variable.'

blank_gateway="$scratch/blank-gateway"
printf ' \n\t' >"$blank_gateway"
if NOVES_GATEWAY_AUTH_TOKEN_FILE="$blank_gateway" \
  bash -c 'source "$1"; resolve_noves_gateway_token' _ \
  "$repo_root/scripts/lib/common.sh" >"$scratch/blank-gateway.out" 2>&1; then
  fail 'a blank gateway credential file was accepted.'
fi
grep -Fq 'blank' "$scratch/blank-gateway.out" ||
  fail 'blank gateway credential file error was unclear.'

if bash -c 'source "$1"; resolve_noves_gateway_token' _ \
  "$repo_root/scripts/lib/common.sh" </dev/null >"$scratch/no-gateway.out" 2>&1; then
  fail 'gateway credential resolution used piped stdin without automation variables.'
fi
grep -Fq 'NOVES_GATEWAY_AUTH_TOKEN or NOVES_GATEWAY_AUTH_TOKEN_FILE' \
  "$scratch/no-gateway.out" ||
  fail 'non-interactive gateway error did not name both automation variables.'

touch "$scratch/values.yaml"
INSTALLER_CALLS="$scratch/helm.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-helm.sh" \
  --standard --values "$scratch/values.yaml" --namespace validator --release cda
grep -Fq -- 'oci://ghcr.io/noves-inc/charts/noves-canton-data-app' "$scratch/helm.calls" ||
  fail 'Helm installer did not use the stable OCI chart reference.'
grep -Fq -- '--version >=4.0.0 <5.0.0' "$scratch/helm.calls" ||
  fail 'Helm installer did not constrain upgrades to chart major v4.'
grep -Fq -- 'publicScanUrl: (.publicScanUrl // "")' "$repo_root/scripts/install-helm.sh" ||
  fail 'Helm installer does not persist the optional public scan URL.'
grep -Fq -- 'NOVES_DATA_APP_INSTALL_REF:-v4' "$repo_root/install.sh" ||
  fail 'the installer does not default nested downloads to the v4 branch.'
grep -Fq -- 'get secret "$database_secret"' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not reuse its existing database credential.'
grep -Fq -- 'get configmap "$result_configmap"' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not detect an existing result.'

guided_result='{"completed":true,"provider":"auth0","appUrl":"https://data.example.com:8443","routingHost":"data.example.com","routingMode":"ingress","routingProvider":"ingress","tlsSecret":"data-example-com-tls","ingressClassName":"nginx","istioGateway":"cluster-ingress/cn-http-gateway","routingAnnotations":{"nginx.ingress.kubernetes.io/proxy-body-size":"20m"},"nodeId":"main-node","participantAddress":"participant:5001","expectedParticipantId":"participant::expected","validatorUrl":"http://validator-app:5003","publicScanUrl":"","expectedNetwork":"mainnet","auth0Domain":"tenant.auth0.com","browserClientId":"browser-client","browserAudience":"https://ledger-api"}'
guided_values="$scratch/guided-operator-values.yaml"
printf '%s\n' \
  'imagePullSecrets:' \
  '  - name: private-registry' \
  'capture:' \
  '  clientIdKey: custom-client-id' \
  >"$guided_values"
INSTALLER_CALLS="$scratch/guided.calls" GUIDED_RESULT="$guided_result" \
  FINAL_VALUES_CAPTURE="$scratch/guided-final-values.json" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-helm.sh" --namespace validator --release cda \
  --values "$guided_values"
if grep -Fq -- 'create secret generic cda-database' "$scratch/guided.calls"; then
  fail 'guided Helm resume replaced the existing database credential.'
fi
if grep -Fq -- 'port-forward' "$scratch/guided.calls"; then
  fail 'guided Helm resume reopened a completed wizard.'
fi
[[ "$(grep -c -- 'upgrade --install cda' "$scratch/guided.calls")" == 2 ]] ||
  fail 'guided Helm resume did not reconcile setup and activate the release.'
[[ "$(grep -c -- "--values $guided_values" "$scratch/guided.calls")" == 2 ]] ||
  fail 'guided Helm setup did not preserve operator values for setup and activation.'
grep -Fq -- '--set routing.provider=none' "$scratch/guided.calls" ||
  fail 'guided Helm setup did not override the operator route during localhost setup.'
grep -Fq -- '--set capture.clientIdKey=client-id' "$scratch/guided.calls" ||
  fail 'guided Helm setup did not retain its installer-owned capture Secret key layout.'
grep -Fq -- 'deployment/${release}-setup-wizard' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not port-forward directly to the Deployment.'
grep -Fq -- '#session=$setup_session_token' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup URL does not carry the one-time browser session.'
jq -e '
  .routing == {
    provider: "ingress",
    host: "data.example.com",
    tlsSecret: "data-example-com-tls",
    annotations: {
      "nginx.ingress.kubernetes.io/proxy-body-size": "20m"
    },
    ingress: {className: "nginx"},
    istio: {gateway: "cluster-ingress/cn-http-gateway"}
  }
' "$scratch/guided-final-values.json" >/dev/null ||
  fail 'guided Helm activation did not preserve the complete routing contract.'
jq -e '
  .capture == {
    existingSecret: "cda-capture-auth",
    ledgerApiUserKey: "ledger-api-user",
    tokenEndpointKey: "token-endpoint",
    clientIdKey: "client-id",
    clientSecretKey: "client-secret",
    audienceKey: "audience",
    scopeKey: "scope"
  }
' "$scratch/guided-final-values.json" >/dev/null ||
  fail 'guided Helm activation did not pin its generated capture Secret key layout.'
grep -Fq -- 'from-literal="session-token=$setup_session_token"' \
  "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not persist a separate browser session token.'

active_helm_marker="$scratch/active-helm-completed"
active_helm_calls="$scratch/active-helm.calls"
active_helm_bootstrap="$scratch/active-helm-bootstrap.check"
INSTALLER_CALLS="$active_helm_calls" \
  BOOTSTRAP_CHECK="$active_helm_bootstrap" \
  ACTIVE_GUIDED_MARKER="$active_helm_marker" \
  ACTIVE_GUIDED_RESULT="$guided_result" \
  NOVES_GATEWAY_AUTH_TOKEN=gateway-token \
  PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-helm.sh" \
  --namespace validator --release active-cda --setup-port 18099
[[ "$(grep -c -- 'upgrade --install active-cda' "$active_helm_calls")" == 2 ]] ||
  fail 'active guided Helm path did not install setup and activate the final release.'
grep -Fq -- 'port-forward deployment/active-cda-setup-wizard 18099:3000' \
  "$active_helm_calls" ||
  fail 'active guided Helm path did not launch the localhost wizard.'
grep -Fq $'helm\tvalidator-admin' "$active_helm_bootstrap" ||
  fail 'active guided Helm path did not bootstrap the administrator credential.'
grep -Fq -- 'delete secret active-cda-setup-token' "$active_helm_calls" ||
  fail 'active guided Helm path retained its setup credential after activation.'

compose_install="$scratch/compose-install"
mkdir -p "$compose_install/docker-compose/.state" \
  "$compose_install/docker-compose/.secrets"
cp "$repo_root/docker-compose/.env.example" "$compose_install/docker-compose/.env"
cp "$repo_root/docker-compose/config/nodes-config.json" \
  "$compose_install/docker-compose/.state/nodes-config.json"
sed -i.bak \
  -e 's/REPLACE_WITH_PARTICIPANT_ID/participant::test/' \
  "$compose_install/docker-compose/.state/nodes-config.json"
rm -f "$compose_install/docker-compose/.state/nodes-config.json.bak"
printf '%s\n' \
  'M2M_INDEXER_ENABLED=true' \
  'M2M_TOKEN_ENDPOINT=https://issuer.example/token' \
  'M2M_CLIENT_ID=capture-client' \
  'M2M_CLIENT_SECRET=capture-secret' \
  'M2M_AUDIENCE=https://ledger-api' \
  'M2M_SCOPE=daml_ledger_api' \
  >"$compose_install/docker-compose/.state/capture.env"
printf 'gateway-token\n' \
  >"$compose_install/docker-compose/.secrets/noves-gateway-auth-token"
chmod 600 "$compose_install/docker-compose/.env" \
  "$compose_install/docker-compose/.state/capture.env" \
  "$compose_install/docker-compose/.secrets/noves-gateway-auth-token"
INSTALLER_CALLS="$scratch/compose.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install"
accounting_file="$compose_install/docker-compose/.state/accounting.env"
[[ -f "$accounting_file" ]] ||
  fail 'Compose installer did not create accounting.env.'
grep -Eq '^ACCOUNTING_TOKEN_ENCRYPTION_KEY=[A-Za-z0-9+/]{43}=$' "$accounting_file" ||
  fail 'Compose installer did not write a 32-byte base64 accounting key.'
accounting_mode="$(stat -f '%Lp' "$accounting_file" 2>/dev/null || stat -c '%a' "$accounting_file")"
[[ "$accounting_mode" == 600 ]] ||
  fail 'Compose installer did not protect accounting.env with mode 0600.'
accounting_checksum="$(shasum -a 256 "$accounting_file" | awk '{print $1}')"
INSTALLER_CALLS="$scratch/compose-rerun.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install"
[[ "$(shasum -a 256 "$accounting_file" | awk '{print $1}')" == "$accounting_checksum" ]] ||
  fail 'Compose installer rotated the accounting encryption key on rerun.'
grep -Fq -- 'compose --env-file .env -f compose.yaml config --quiet' "$scratch/compose.calls" ||
  fail 'Compose installer did not validate the rendered application manifest.'
grep -Fq -- 'network inspect splice-validator_splice_validator' "$scratch/compose.calls" ||
  fail 'Compose installer did not validate the configured Canton Docker network.'
grep -Fq -- 'compose --env-file .env -f compose.yaml pull' "$scratch/compose.calls" ||
  fail 'Compose installer did not validate registry access by pulling images.'
grep -Fq -- 'compose --env-file .env -f compose.yaml up -d' "$scratch/compose.calls" ||
  fail 'Compose installer did not use the standard Compose application path.'
grep -Fq -- 'http://127.0.0.1:8090/ready' "$scratch/compose.calls" ||
  fail 'Compose installer did not wait for backend readiness.'

cp "$accounting_file" "$scratch/accounting.env.valid"
printf 'ACCOUNTING_TOKEN_ENCRYPTION_KEY=invalid\n' >"$accounting_file"
if INSTALLER_CALLS="$scratch/invalid-accounting.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install" \
  >"$scratch/invalid-accounting.out" 2>&1; then
  fail 'Compose installer accepted an invalid retained accounting key.'
fi
grep -Fq '32-byte base64 ACCOUNTING_TOKEN_ENCRYPTION_KEY' \
  "$scratch/invalid-accounting.out" ||
  fail 'invalid accounting key error did not explain the required format.'
cp "$scratch/accounting.env.valid" "$accounting_file"

cp "$compose_install/docker-compose/.state/capture.env" "$scratch/capture.env.valid"
grep -v '^M2M_CLIENT_SECRET=' "$scratch/capture.env.valid" \
  >"$compose_install/docker-compose/.state/capture.env"
if INSTALLER_CALLS="$scratch/incomplete-capture.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install" \
  >"$scratch/incomplete-capture.out" 2>&1; then
  fail 'Compose installer accepted capture credentials without a client secret.'
fi
grep -Fq 'M2M_CLIENT_SECRET' "$scratch/incomplete-capture.out" ||
  fail 'incomplete capture error did not name M2M_CLIENT_SECRET.'
cp "$scratch/capture.env.valid" "$compose_install/docker-compose/.state/capture.env"

cp "$compose_install/docker-compose/.state/nodes-config.json" "$scratch/nodes-config.valid"
sed -i.bak \
  -e 's/participant::test/REPLACE_WITH_PARTICIPANT_ID/' \
  "$compose_install/docker-compose/.state/nodes-config.json"
rm -f "$compose_install/docker-compose/.state/nodes-config.json.bak"
if INSTALLER_CALLS="$scratch/placeholder-node.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install" \
  >"$scratch/placeholder-node.out" 2>&1; then
  fail 'Compose installer accepted the placeholder participant ID.'
fi
grep -Fq 'REPLACE_WITH_PARTICIPANT_ID' "$scratch/placeholder-node.out" ||
  fail 'placeholder participant error did not name the value to replace.'
cp "$scratch/nodes-config.valid" \
  "$compose_install/docker-compose/.state/nodes-config.json"

if INSTALLER_CALLS="$scratch/missing-network.calls" DOCKER_NETWORK_MISSING=1 \
  PATH="$fake_bin:$PATH" "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install" \
  >"$scratch/missing-network.out" 2>&1; then
  fail 'Compose installer accepted a missing Canton Docker network.'
fi
grep -Fq "Docker network 'splice-validator_splice_validator' does not exist" \
  "$scratch/missing-network.out" ||
  fail 'missing Docker network error did not name the configured network.'

if INSTALLER_CALLS="$scratch/pull-failure.calls" DOCKER_PULL_FAIL=1 \
  PATH="$fake_bin:$PATH" "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install" \
  >"$scratch/pull-failure.out" 2>&1; then
  fail 'Compose installer ignored an image pull failure.'
fi
grep -Fq 'Log in to the configured registries and retry' \
  "$scratch/pull-failure.out" ||
  fail 'image pull failure did not explain the registry login action.'

grep -Fq -- 'nodes-config.json' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not persist the wizard participant configuration.'
grep -Fq -- 'setup_user="$(id -u):$(id -g)"' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not map setup writes to the invoking host user.'
grep -Fq -- 'M2M_TOKEN_ENDPOINT M2M_CLIENT_ID M2M_CLIENT_SECRET M2M_AUDIENCE' \
  "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not validate capture credentials before activation.'
grep -Fq -- 'SETUP_SESSION_TOKEN' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not persist a separate browser session token.'

active_compose_install="$scratch/active-compose-install"
active_compose_state="$active_compose_install/docker-compose/.state"
active_compose_calls="$scratch/active-compose.calls"
active_compose_bootstrap="$scratch/active-compose-bootstrap.check"
INSTALLER_CALLS="$active_compose_calls" \
  BOOTSTRAP_CHECK="$active_compose_bootstrap" \
  ACTIVE_COMPOSE_STATE_DIR="$active_compose_state" \
  ACTIVE_COMPOSE_RESULT="$guided_result" \
  NOVES_GATEWAY_AUTH_TOKEN=gateway-token \
  PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --directory "$active_compose_install"
grep -Fq $'compose\tvalidator-admin' "$active_compose_bootstrap" ||
  fail 'active guided Compose path did not bootstrap the administrator credential.'
grep -Fq -- 'compose --env-file .env -f compose.setup.yaml down' \
  "$active_compose_calls" ||
  fail 'active guided Compose path did not remove the setup stack.'
grep -Fq -- 'compose --env-file .env -f compose.yaml up -d --wait' \
  "$active_compose_calls" ||
  fail 'active guided Compose path did not wait for final application readiness.'
jq -e '.completed == true' "$active_compose_state/values.json" >/dev/null ||
  fail 'active guided Compose path did not persist completed setup state.'
if grep -Fq 'validator-secret' "$active_compose_state/capture.env"; then
  fail 'active guided Compose path persisted the validator administrator credential.'
fi

bootstrap_calls="$scratch/bootstrap.calls"
bootstrap_check="$scratch/bootstrap.check"
INSTALLER_CALLS="$bootstrap_calls" BOOTSTRAP_CHECK="$bootstrap_check" PATH="$fake_bin:$PATH" \
  bash -c 'source "$1"; bootstrap_helm_setup_admin validator "$2" "$3" "$4"' _ \
  "$repo_root/scripts/lib/setup-admin.sh" \
  splice-app-validator-ledger-api-auth http://127.0.0.1:8099 setup-secret
INSTALLER_CALLS="$bootstrap_calls" BOOTSTRAP_CHECK="$bootstrap_check" PATH="$fake_bin:$PATH" \
  bash -c 'source "$1"; bootstrap_helm_setup_admin validator "$2" "$3" "$4"' _ \
  "$repo_root/scripts/lib/setup-admin.sh" \
  custom-admin-secret http://127.0.0.1:8099 setup-secret
[[ "$(grep -c $'^helm\tvalidator-admin$' "$bootstrap_check")" == 2 ]] ||
  fail 'Helm administrator bootstrap did not support default and overridden Secrets.'

INSTALLER_CALLS="$bootstrap_calls" BOOTSTRAP_CHECK="$bootstrap_check" PATH="$fake_bin:$PATH" \
  bash -c 'source "$1"; bootstrap_compose_setup_admin "" "$2" "$3" "$4"' _ \
  "$repo_root/scripts/lib/setup-admin.sh" splice-validator_splice_validator \
  http://127.0.0.1:8099 setup-secret
grep -Fq $'compose\tvalidator-admin' "$bootstrap_check" ||
  fail 'Compose administrator bootstrap did not discover the validator container.'
grep -Fq -- '--filter network=splice-validator_splice_validator' "$bootstrap_calls" ||
  fail 'Compose administrator discovery did not stay on the configured Canton network.'

if INSTALLER_CALLS="$bootstrap_calls" BOOTSTRAP_CHECK="$bootstrap_check" \
  DOCKER_VALIDATORS='' PATH="$fake_bin:$PATH" \
  bash -c 'source "$1"; bootstrap_compose_setup_admin "" "$2" "$3" "$4"' _ \
  "$repo_root/scripts/lib/setup-admin.sh" splice-validator_splice_validator \
  http://127.0.0.1:8099 setup-secret >"$scratch/no-validator.out" 2>&1; then
  fail 'Compose administrator discovery accepted zero validator containers.'
fi
grep -Fq 'No running Compose validator' "$scratch/no-validator.out" ||
  fail 'zero-validator discovery did not explain manual fallback.'

if INSTALLER_CALLS="$bootstrap_calls" BOOTSTRAP_CHECK="$bootstrap_check" \
  DOCKER_VALIDATORS='validator-one validator-two' PATH="$fake_bin:$PATH" \
  bash -c 'source "$1"; bootstrap_compose_setup_admin "" "$2" "$3" "$4"' _ \
  "$repo_root/scripts/lib/setup-admin.sh" \
  splice-validator_splice_validator http://127.0.0.1:8099 setup-secret \
  >"$scratch/multiple-validator.out" 2>&1; then
  fail 'Compose administrator discovery accepted multiple validator containers.'
fi
grep -Fq -- '--validator-container' "$scratch/multiple-validator.out" ||
  fail 'multiple validator discovery did not explain the override.'

INSTALLER_CALLS="$bootstrap_calls" BOOTSTRAP_CHECK="$bootstrap_check" \
  DOCKER_VALIDATORS='validator-one validator-two' PATH="$fake_bin:$PATH" \
  bash -c 'source "$1"; bootstrap_compose_setup_admin validator-two "$2" "$3" "$4"' _ \
  "$repo_root/scripts/lib/setup-admin.sh" \
  splice-validator_splice_validator http://127.0.0.1:8099 setup-secret
if INSTALLER_CALLS="$bootstrap_calls" BOOTSTRAP_CHECK="$bootstrap_check" \
  DOCKER_VALIDATOR_LABEL=other PATH="$fake_bin:$PATH" \
  bash -c 'source "$1"; bootstrap_compose_setup_admin validator-one "$2" "$3" "$4"' _ \
  "$repo_root/scripts/lib/setup-admin.sh" \
  splice-validator_splice_validator http://127.0.0.1:8099 setup-secret \
  >"$scratch/invalid-validator.out" 2>&1; then
  fail 'Compose administrator discovery accepted a non-validator container override.'
fi
if grep -Fq 'validator-secret' "$bootstrap_calls"; then
  fail 'administrator client secret appeared in installer command arguments.'
fi
grep -Fq -- '--participant-admin-secret NAME' "$repo_root/scripts/install-helm.sh" ||
  fail 'Helm installer does not document the participant administrator Secret override.'
grep -Fq -- '--validator-container NAME' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not document the validator container override.'
grep -Fq -- 'scripts/lib/setup-admin.sh' "$repo_root/install.sh" ||
  fail 'remote installer does not download the administrator bootstrap library.'

for script in "$repo_root/install.sh" "$repo_root"/scripts/*.sh "$repo_root"/scripts/lib/*.sh; do
  bash -n "$script"
done

if "$repo_root/scripts/migrate-v3.sh" \
  --source-version 3.16.0 \
  --backup-confirmed \
  --old-workload-stopped \
  --volume old-data >"$scratch/invalid-migration.out" 2>&1; then
  fail 'migration launcher accepted a source other than Data App v3.16.1.'
fi
grep -Fq -- 'Data App v3.16.1' "$scratch/invalid-migration.out" ||
  fail 'migration launcher did not explain the v3.16.1 prerequisite.'

if grep -RFiq -- 'python' "$repo_root/install.sh" "$repo_root/scripts"; then
  fail 'Customer installer mentions an internal implementation language.'
fi
if grep -RFiq -- '/var/run/docker.sock' "$repo_root/install.sh" "$repo_root/scripts"; then
  fail 'Customer installer mounts the Docker socket.'
fi

printf 'installer tests passed\n'

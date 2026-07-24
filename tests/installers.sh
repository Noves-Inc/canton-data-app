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
EOF
cat >"$fake_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$INSTALLER_CALLS"
if [[ "$*" == *"get secret"*"splice-app-validator-ledger-api-auth"*"-o json"* ]] \
  || [[ "$*" == *"get secret"*"custom-admin-secret"*"-o json"* ]]; then
  printf '%s' '{"data":{"url":"aHR0cHM6Ly9zc28uZXhhbXBsZS5jb20vcmVhbG1zL2NhbnRvbi9wcm90b2NvbC9vcGVuaWQtY29ubmVjdC90b2tlbg==","ledger-api-user":"dmFsaWRhdG9yLWFkbWlu","client-id":"dmFsaWRhdG9yLWNsaWVudA==","client-secret":"dmFsaWRhdG9yLXNlY3JldA==","audience":"aHR0cHM6Ly9sZWRnZXItYXBp","scope":"ZGFtbF9sZWRnZXJfYXBp"}}'
elif [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get secret"*"setup-token"*"-o jsonpath={.data.token}"* ]]; then
  printf 'c2V0dXAtc2VjcmV0'
elif [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get secret"*"setup-token"*"-o jsonpath={.data.session-token}"* ]]; then
  printf 'YnJvd3Nlci1zZWNyZXQ='
elif [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get secret"*"capture-auth"*"-o json"* ]]; then
  printf '%s' '{"data":{"ledger-api-user":"Y2FwdHVyZS11c2Vy","token-endpoint":"aHR0cHM6Ly9pc3N1ZXIuZXhhbXBsZS90b2tlbg==","client-id":"Y2FwdHVyZS1jbGllbnQ=","client-secret":"c2VjcmV0","audience":"aHR0cHM6Ly9sZWRnZXItYXBp","scope":""}}'
elif [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get configmap"*"setup-results"* ]]; then
  printf '%s' "$GUIDED_RESULT"
fi
exit 0
EOF
cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "compose version" ]]; then
  exit 0
fi
printf '%s\n' "$*" >>"$INSTALLER_CALLS"
if [[ "$1" == ps && "$*" == *"com.docker.compose.service=validator"* ]]; then
  if [[ -n "${DOCKER_VALIDATORS+x}" ]]; then
    printf '%s\n' $DOCKER_VALIDATORS
  else
    printf '%s\n' validator-one
  fi
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
if [[ "$*" == *"--data-binary @-"* ]]; then
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
  printf '%s' '{"status":"stored"}'
fi
EOF
chmod +x "$fake_bin/helm" "$fake_bin/kubectl" "$fake_bin/docker" "$fake_bin/curl"

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

guided_result='{"completed":true,"provider":"auth0","appUrl":"https://data.example.com:8443","routingHost":"data.example.com","routingMode":"istio","nodeId":"main-node","participantAddress":"participant:5001","expectedParticipantId":"participant::expected","validatorUrl":"http://validator-app:5003","publicScanUrl":"","expectedNetwork":"mainnet","auth0Domain":"tenant.auth0.com","browserClientId":"browser-client","browserAudience":"https://ledger-api"}'
INSTALLER_CALLS="$scratch/guided.calls" GUIDED_RESULT="$guided_result" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-helm.sh" --namespace validator --release cda
if grep -Fq -- 'create secret generic cda-database' "$scratch/guided.calls"; then
  fail 'guided Helm resume replaced the existing database credential.'
fi
if grep -Fq -- 'port-forward' "$scratch/guided.calls"; then
  fail 'guided Helm resume reopened a completed wizard.'
fi
[[ "$(grep -c -- 'upgrade --install cda' "$scratch/guided.calls")" == 2 ]] ||
  fail 'guided Helm resume did not reconcile setup and activate the release.'
grep -Fq -- 'deployment/${release}-setup-wizard' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not port-forward directly to the Deployment.'
grep -Fq -- '#session=$setup_session_token' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup URL does not carry the one-time browser session.'
grep -Fq -- "jq -er '.routingHost'" "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm activation does not use the parsed routing hostname.'
grep -Fq -- 'from-literal="session-token=$setup_session_token"' \
  "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not persist a separate browser session token.'

compose_install="$scratch/compose-install"
mkdir -p "$compose_install/docker-compose/.state" \
  "$compose_install/docker-compose/.secrets"
cp "$repo_root/docker-compose/.env.example" "$compose_install/docker-compose/.env"
cp "$repo_root/docker-compose/config/nodes-config.json" \
  "$compose_install/docker-compose/.state/nodes-config.json"
printf 'M2M_INDEXER_ENABLED=true\n' \
  >"$compose_install/docker-compose/.state/capture.env"
printf 'gateway-token\n' \
  >"$compose_install/docker-compose/.secrets/noves-gateway-auth-token"
chmod 600 "$compose_install/docker-compose/.env" \
  "$compose_install/docker-compose/.state/capture.env" \
  "$compose_install/docker-compose/.secrets/noves-gateway-auth-token"
INSTALLER_CALLS="$scratch/compose.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install"
grep -Fq -- 'compose --env-file .env -f compose.yaml up -d' "$scratch/compose.calls" ||
  fail 'Compose installer did not use the standard Compose application path.'
grep -Fq -- 'nodes-config.json' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not persist the wizard participant configuration.'
grep -Fq -- 'setup_user="$(id -u):$(id -g)"' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not map setup writes to the invoking host user.'
grep -Fq -- 'M2M_TOKEN_ENDPOINT M2M_CLIENT_ID M2M_CLIENT_SECRET M2M_AUDIENCE' \
  "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not validate capture credentials before activation.'
grep -Fq -- 'SETUP_SESSION_TOKEN' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not persist a separate browser session token.'

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

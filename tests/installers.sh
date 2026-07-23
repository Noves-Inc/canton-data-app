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
if [[ -n "${GUIDED_RESULT:-}" && "$*" == *"get secret"*"setup-token"*"-o jsonpath={.data.token}"* ]]; then
  printf 'c2V0dXAtc2VjcmV0'
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
EOF
chmod +x "$fake_bin/helm" "$fake_bin/kubectl" "$fake_bin/docker"

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
grep -Fq -- 'CDA_INSTALL_REF:-v4' "$repo_root/install.sh" ||
  fail 'the installer does not default nested downloads to the v4 branch.'
grep -Fq -- 'get secret "$database_secret"' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not reuse its existing database credential.'
grep -Fq -- 'get configmap "$result_configmap"' "$repo_root/scripts/install-helm.sh" ||
  fail 'guided Helm setup does not detect an existing result.'

guided_result='{"completed":true,"provider":"auth0","appUrl":"https://data.example.com","routingMode":"istio","nodeId":"main-node","participantAddress":"participant:5001","expectedParticipantId":"participant::expected","validatorUrl":"http://validator-app:5003","publicScanUrl":"","expectedNetwork":"mainnet","auth0Domain":"tenant.auth0.com","browserClientId":"browser-client","browserAudience":"https://ledger-api"}'
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

compose_install="$scratch/compose-install"
mkdir -p "$compose_install/docker-compose/.state"
cp "$repo_root/docker-compose/.env.example" "$compose_install/docker-compose/.env"
cp "$repo_root/docker-compose/config/nodes-config.json" \
  "$compose_install/docker-compose/.state/nodes-config.json"
printf 'M2M_INDEXER_ENABLED=true\n' \
  >"$compose_install/docker-compose/.state/capture.env"
chmod 600 "$compose_install/docker-compose/.env" \
  "$compose_install/docker-compose/.state/capture.env"
INSTALLER_CALLS="$scratch/compose.calls" PATH="$fake_bin:$PATH" \
  "$repo_root/scripts/install-compose.sh" \
  --standard --directory "$compose_install"
grep -Fq -- 'compose --env-file .env -f compose.yaml up -d' "$scratch/compose.calls" ||
  fail 'Compose installer did not use the standard Compose application path.'
grep -Fq -- 'nodes-config.json' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not persist the wizard participant configuration.'
grep -Fq -- 'setup_uid="$(id -u)"' "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not map setup writes to the invoking host user.'
grep -Fq -- 'M2M_TOKEN_ENDPOINT M2M_CLIENT_ID M2M_CLIENT_SECRET M2M_AUDIENCE' \
  "$repo_root/scripts/install-compose.sh" ||
  fail 'Compose installer does not validate capture credentials before activation.'

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

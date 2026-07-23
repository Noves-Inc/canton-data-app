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

for script in "$repo_root/install.sh" "$repo_root"/scripts/*.sh "$repo_root"/scripts/lib/*.sh; do
  bash -n "$script"
done

if grep -RFiq -- 'python' "$repo_root/install.sh" "$repo_root/scripts"; then
  fail 'Customer installer mentions an internal implementation language.'
fi
if grep -RFiq -- '/var/run/docker.sock' "$repo_root/install.sh" "$repo_root/scripts"; then
  fail 'Customer installer mounts the Docker socket.'
fi

printf 'installer tests passed\n'

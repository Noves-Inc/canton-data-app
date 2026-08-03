#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/node-config-upgrade.sh
source "$root/scripts/lib/node-config-upgrade.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_equals() { cmp -s "$1" "$2" || fail "$1 differs from $2"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains $2"; }

node_config_contracts() {
  local config="$scratch/nodes-config.json" original="$scratch/original.json" mode

  printf '%s\n' '{"nodes":{"main":{"addr":"participant:5001"}}}' >"$config"
  cp "$config" "$original"
  upgrade_nodes_config_file "$config"
  assert_file_equals "$config" "$original"
  [[ ! -e "$config.pre-retired-field-upgrade.bak" ]] || fail "current config created a backup"

  printf '%s\n' '{"nodes":{"main":{"expected_synchronizer_id":null}}}' >"$config"
  upgrade_nodes_config_file "$config"
  jq -e '.nodes.main | has("expected_synchronizer_id") | not' "$config" >/dev/null

  printf '%s\n' '{"nodes":{"main":{"expected_synchronizer_id":""},"other":{"expected_synchronizer_id":" \t\n "}}}' >"$config"
  upgrade_nodes_config_file "$config"
  jq -e '[.nodes[] | has("expected_synchronizer_id")] | any | not' "$config" >/dev/null

  printf '%s\n' '{"nodes":{"one":{"addr":"a","expected_synchronizer_id":" "},"two":{"keep":true},"three":{"expected_synchronizer_id":null}}}' >"$config"
  upgrade_nodes_config_file "$config"
  jq -e '.nodes.one.addr == "a" and .nodes.two.keep and (.nodes.three | has("expected_synchronizer_id") | not)' "$config" >/dev/null
  rm -f "$config.pre-retired-field-upgrade.bak"

  printf '%s\n' '{"nodes":{"affected":{"expected_synchronizer_id":"chosen"}}}' >"$config"
  cp "$config" "$original"
  if upgrade_nodes_config_file "$config" >"$scratch/nonempty.out" 2>&1; then
    fail "nonempty retired value succeeded"
  fi
  assert_contains "$scratch/nonempty.out" "affected"
  assert_contains "$scratch/nonempty.out" "synchronizer_alias"
  assert_file_equals "$config" "$original"
  [[ ! -e "$config.pre-retired-field-upgrade.bak" ]] || fail "refused config created a backup"

  for value in 0 false '[]' '{}'; do
    printf '{"nodes":{"affected":{"expected_synchronizer_id":%s}}}\n' "$value" >"$config"
    cp "$config" "$original"
    if upgrade_nodes_config_file "$config" >/dev/null 2>&1; then
      fail "non-string historical value $value succeeded"
    fi
    assert_file_equals "$config" "$original"
  done

  printf '%s\n' '{"nodes":' >"$config"
  cp "$config" "$original"
  if upgrade_nodes_config_file "$config" >/dev/null 2>&1; then
    fail "invalid JSON succeeded"
  fi
  assert_file_equals "$config" "$original"

  printf '%s\n' '{"nodes":{"main":{"expected_synchronizer_id":null}}}' >"$config"
  chmod 640 "$config"
  upgrade_nodes_config_file "$config"
  [[ -f "$config.pre-retired-field-upgrade.bak" ]] || fail "rewrite did not create backup"
  assert_file_equals "$config.pre-retired-field-upgrade.bak" <(printf '%s\n' '{"nodes":{"main":{"expected_synchronizer_id":null}}}')
  mode="$(node_config_file_mode "$config")"
  [[ "$mode" == 640 ]] || fail "rewrite changed mode to $mode"
  cp "$config" "$original"
  upgrade_nodes_config_file "$config"
  assert_file_equals "$config" "$original"
  [[ "$(find "$scratch" -name 'nodes-config.json.pre-retired-field-upgrade.bak' | wc -l | tr -d ' ')" == 1 ]] || fail "second run created another backup"

  printf '%s\n' '{"nodes":{"main":{"expected_synchronizer_id":null}}}' >"$config"
  cp "$config" "$original"
  local readonly_dir="$scratch/readonly"
  mkdir "$readonly_dir"
  mv "$config" "$readonly_dir/nodes-config.json"
  mv "$original" "$readonly_dir/original.json"
  cp "$readonly_dir/nodes-config.json" "$readonly_dir/nodes-config.json.pre-retired-field-upgrade.bak"
  chmod 500 "$readonly_dir"
  if upgrade_nodes_config_file "$readonly_dir/nodes-config.json" >/dev/null 2>&1; then
    chmod 700 "$readonly_dir"
    fail "temporary-write failure succeeded"
  fi
  chmod 700 "$readonly_dir"
  assert_file_equals "$readonly_dir/nodes-config.json" "$readonly_dir/original.json"

  local invalid_backup_dir="$scratch/invalid-backup"
  mkdir "$invalid_backup_dir"
  config="$invalid_backup_dir/nodes-config.json"
  printf '%s\n' '{"nodes":{"main":{"expected_synchronizer_id":null}}}' >"$config"
  printf '%s\n' 'poisoned partial backup' >"$config.pre-retired-field-upgrade.bak"
  cp "$config" "$original"
  if upgrade_nodes_config_file "$config" >"$scratch/invalid-backup.out" 2>&1; then
    fail "invalid existing backup was accepted"
  fi
  assert_contains "$scratch/invalid-backup.out" 'backup'
  assert_file_equals "$config" "$original"

  local partial_bin="$scratch/partial-copy-bin" partial_dir="$scratch/partial-backup"
  mkdir "$partial_bin" "$partial_dir"
  config="$partial_dir/nodes-config.json"
  printf '%s\n' '{"nodes":{"main":{"expected_synchronizer_id":null}}}' >"$config"
  cp "$config" "$original"
  cat >"$partial_bin/cp" <<'EOF'
#!/usr/bin/env bash
printf 'partial' >"${@: -1}"
exit 1
EOF
  chmod +x "$partial_bin/cp"
  if PATH="$partial_bin:$PATH" upgrade_nodes_config_file "$config" >/dev/null 2>&1; then
    fail "partial backup copy succeeded"
  fi
  assert_file_equals "$config" "$original"
  [[ ! -e "$config.pre-retired-field-upgrade.bak" ]] || fail "partial backup was published"
  [[ -z "$(find "$partial_dir" -name '.nodes-config-backup.*' -print -quit)" ]] || fail "backup temporary file was retained"

  local stat_bin="$scratch/gnu-stat-bin"
  mkdir "$stat_bin"
  cat >"$stat_bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-f" ]]; then exit 1; fi
[[ "$1" == "-c" && "$2" == "%a" ]] || exit 2
printf '640\n'
EOF
  chmod +x "$stat_bin/stat"
  [[ "$(PATH="$stat_bin:$PATH" node_config_file_mode "$original")" == 640 ]] || fail "GNU stat fallback did not return the mode"
}

write_compose_fixture() {
  local install_dir="$1"
  mkdir -p "$install_dir/docker-compose/.state/certificates"
  cp "$root/docker-compose/.env.example" "$install_dir/docker-compose/.env"
  printf '%s\n' 'M2M_TOKEN_ENDPOINT=https://auth.example/token' 'M2M_CLIENT_ID=m2m_indexing' 'M2M_CLIENT_SECRET=secret' 'M2M_AUDIENCE=audience' >"$install_dir/docker-compose/.state/m2m-indexing.env"
}

compose_contracts() {
  local bin="$scratch/compose-bin" log="$scratch/compose.log" install_dir="$scratch/compose-install"
  mkdir "$bin"
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$INSTALLER_LOG"
case "$1 $2" in
  'compose version') exit 0 ;;
  'network inspect') exit 0 ;;
esac
if [[ "$1 $2" == 'compose --env-file' && " $* " == *' config --format json '* ]]; then
  printf '%s\n' '{"services":{"backend":{"image":"backend:test","volumes":[{"type":"volume","target":"/exports","source":"exports"}]}},"volumes":{"exports":{"name":"exports"}}}'
fi
exit 0
EOF
  cat >"$bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >>"$INSTALLER_LOG"
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
EOF
  cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$INSTALLER_LOG"
exit 0
EOF
  chmod +x "$bin/docker" "$bin/openssl" "$bin/curl"

  local symlink_install="$scratch/symlink-install" symlink_target="$scratch/installer-symlink-target"
  write_compose_fixture "$symlink_install"
  mkdir -p "$symlink_target/main-node"
  printf '%s\n' 'must-remain-private' >"$symlink_target/main-node/token"
  chmod 0710 "$symlink_target"
  chmod 0600 "$symlink_target/main-node/token"
  ln -s "$symlink_target" "$symlink_install/docker-compose/.state/m2m-indexing-secrets"
  local symlink_dir_mode_before symlink_file_mode_before
  symlink_dir_mode_before="$(node_config_file_mode "$symlink_target")"
  symlink_file_mode_before="$(node_config_file_mode "$symlink_target/main-node/token")"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$symlink_install" >"$scratch/installer-symlink.out" 2>&1; then
    fail "installer accepted a symlinked m2m_indexing-secret root"
  fi
  assert_contains "$scratch/installer-symlink.out" 'real directory'
  [[ "$(node_config_file_mode "$symlink_target")" == "$symlink_dir_mode_before" ]] ||
    fail "installer changed symlink target directory permissions"
  [[ "$(node_config_file_mode "$symlink_target/main-node/token")" == "$symlink_file_mode_before" ]] ||
    fail "installer changed symlink target file permissions"
  [[ ! -s "$log" ]] || fail "installer invoked Docker before rejecting the symlinked m2m_indexing-secret root"

  write_compose_fixture "$install_dir"
  printf '%s\n' '{"nodes":{"main-node":{"expected_synchronizer_id":" "}}}' >"$install_dir/docker-compose/.state/nodes-config.json"
  : >"$log"
  INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >/dev/null
  jq -e '.nodes["main-node"] | has("expected_synchronizer_id") | not' "$install_dir/docker-compose/.state/nodes-config.json" >/dev/null
  [[ -f "$install_dir/docker-compose/.state/nodes-config.json.pre-retired-field-upgrade.bak" ]] || fail "compose installer did not preserve upgrade backup"
  assert_contains "$log" 'docker compose --env-file .env -f compose.yaml config --quiet'

  rm -rf "$install_dir"
  write_compose_fixture "$install_dir"
  printf '%s\n' 'unused-invalid-global-config' >"$install_dir/docker-compose/.state/m2m-indexing.env"
  printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001","m2mIndexing":{"static_token_file":"/m2m-indexing-secrets/main-node/token"}}}}' >"$install_dir/docker-compose/.state/nodes-config.json"
  mkdir -p "$install_dir/docker-compose/.state/m2m-indexing-secrets/main-node"
  printf '%s\n' 'test-static-token' >"$install_dir/docker-compose/.state/m2m-indexing-secrets/main-node/token"
  : >"$log"
  INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >/dev/null
  grep -Eq 'M2M_INDEXER_ENABLED:[[:space:]]*"true"' "$install_dir/docker-compose/compose.yaml" ||
    fail "explicit Compose install did not keep M2M_INDEXER_ENABLED=true"
  assert_contains "$log" 'docker run --rm --user 0:0 --volume'
  assert_contains "$log" '/m2m-indexing-secrets'
  assert_contains "$log" 'docker compose --env-file .env -f compose.yaml up -d'

  rm -rf "$install_dir"
  write_compose_fixture "$install_dir"
  printf '%s\n' 'invalid-global-config' >"$install_dir/docker-compose/.state/m2m-indexing.env"
  printf '%s\n' '{"nodes":{"explicit":{"m2mIndexing":{"static_token_file":"/m2m-indexing-secrets/explicit/token"}},"fallback":{}}}' >"$install_dir/docker-compose/.state/nodes-config.json"
  mkdir -p "$install_dir/docker-compose/.state/m2m-indexing-secrets/explicit"
  printf '%s\n' 'test-static-token' >"$install_dir/docker-compose/.state/m2m-indexing-secrets/explicit/token"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >"$scratch/fallback-invalid.out" 2>&1; then
    fail "invalid global M2M indexing file was accepted for a fallback node"
  fi
  assert_contains "$scratch/fallback-invalid.out" 'M2M_TOKEN_ENDPOINT'
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml config'

  rm -rf "$install_dir"
  write_compose_fixture "$install_dir"
  printf '%s\n' '{"nodes":{"bad-cert":{"expected_synchronizer_id":" ","cert_file":"/certificates/missing.pem"}}}' >"$install_dir/docker-compose/.state/nodes-config.json"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >"$scratch/certificate-order.out" 2>&1; then
    fail "missing certificate was accepted"
  fi
  assert_contains "$scratch/certificate-order.out" '/certificates/missing.pem'
  jq -e '.nodes["bad-cert"] | has("expected_synchronizer_id") | not' "$install_dir/docker-compose/.state/nodes-config.json" >/dev/null ||
    fail "retired-field upgrade did not finish before certificate validation"
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml config'
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml pull'

  rm -rf "$install_dir"
  write_compose_fixture "$install_dir"
  printf '%s\n' '{"nodes":{"ambiguous":{"expected_synchronizer_id":"global"}}}' >"$install_dir/docker-compose/.state/nodes-config.json"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >"$scratch/compose-error.out" 2>&1; then
    fail "compose installer accepted ambiguous retained state"
  fi
  assert_contains "$scratch/compose-error.out" 'ambiguous'
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml config'
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml pull'
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml up'
}

migration_contracts() {
  local bin="$scratch/migration-bin" log="$scratch/migration.log"
  local compose_dir="$scratch/migration-install/docker-compose"
  mkdir -p "$bin"
  cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$INSTALLER_LOG"
exit 0
EOF
  chmod +x "$bin/docker"

  write_migration_fixture() {
    rm -rf "$compose_dir"
    mkdir -p "$compose_dir/.state/certificates" "$compose_dir/.state/m2m-indexing-secrets/main-node"
    printf '%s\n' 'DATABASE_PASSWORD=test-password' >"$compose_dir/.env"
    printf '%s\n' 'test-static-token' >"$compose_dir/.state/m2m-indexing-secrets/main-node/token"
  }

  write_migration_fixture
  printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001","expected_synchronizer_id":" ","m2mIndexing":{"static_token_file":"/m2m-indexing-secrets/main-node/token"}}}}' >"$compose_dir/.state/nodes-config.json"
  : >"$log"
  INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/migrate-v3.sh" \
    --source-version 3.16.1 --backup-confirmed --old-workload-stopped \
    --volume v3-database --directory "$compose_dir" >/dev/null
  jq -e '.nodes["main-node"] | has("expected_synchronizer_id") | not' \
    "$compose_dir/.state/nodes-config.json" >/dev/null ||
    fail "migration wrapper did not upgrade retained node configuration"
  [[ -f "$compose_dir/.state/nodes-config.json.pre-retired-field-upgrade.bak" ]] ||
    fail "migration wrapper did not preserve the node configuration backup"
  assert_contains "$log" 'compose --env-file .env -f compose.yaml -f compose.migrate-v3.yaml up -d'

  write_migration_fixture
  printf '%s\n' '{"nodes":{"fallback":{"addr":"participant:5001"}}}' >"$compose_dir/.state/nodes-config.json"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/migrate-v3.sh" \
    --source-version 3.16.1 --backup-confirmed --old-workload-stopped \
    --volume v3-database --directory "$compose_dir" >"$scratch/migration-global.out" 2>&1; then
    fail "migration wrapper accepted a fallback node without global M2M indexing credentials"
  fi
  assert_contains "$scratch/migration-global.out" '.state/m2m-indexing.env'
  [[ ! -s "$log" ]] || fail "migration wrapper started Docker after M2M indexing validation failed"

  write_migration_fixture
  printf '%s\n' '{"nodes":{"ambiguous":{"addr":"participant:5001","expected_synchronizer_id":"chosen","m2mIndexing":{"static_token_file":"/m2m-indexing-secrets/main-node/token"}}}}' >"$compose_dir/.state/nodes-config.json"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/migrate-v3.sh" \
    --source-version 3.16.1 --backup-confirmed --old-workload-stopped \
    --volume v3-database --directory "$compose_dir" >"$scratch/migration-ambiguous.out" 2>&1; then
    fail "migration wrapper accepted an ambiguous retired synchronizer value"
  fi
  assert_contains "$scratch/migration-ambiguous.out" 'synchronizer_alias'
  [[ ! -s "$log" ]] || fail "migration wrapper started Docker after node upgrade failed"
}

helm_contracts() {
  local bin="$scratch/helm-bin" log="$scratch/helm.log" values="$scratch/values.yaml"
  mkdir "$bin"
  printf '{}\n' >"$values"
  cat >"$bin/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$INSTALLER_LOG"
EOF
  chmod +x "$bin/helm"
  local script="$root/scripts/install-helm.sh"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$script" --values "$values" >/dev/null 2>&1; then fail "missing context succeeded"; fi
  [[ ! -s "$log" ]] || fail "helm ran without context"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$script" --kube-context test >/dev/null 2>&1; then fail "missing values succeeded"; fi
  [[ ! -s "$log" ]] || fail "helm ran without values"
  for version in '' '>=4.0.0 <5.0.0' '4.*' 'four' '04.0.0' '4.00.0' '4.0.01' '4.0.0-01' '4.0.0-' '4.0.0+' '4.0.0+bad?'; do
    if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$script" --kube-context test --values "$values" --version "$version" >/dev/null 2>&1; then fail "invalid version $version succeeded"; fi
    [[ ! -s "$log" ]] || fail "helm ran for invalid version $version"
  done
  INSTALLER_LOG="$log" PATH="$bin:$PATH" "$script" --kube-context target --namespace ns --release release --values "$values"
  local argv
  argv="$(tr '\n' ' ' <"$log")"
  local default_version
  default_version="$(awk '/^version:/{print $2; exit}' "$root/chart/noves-canton-data-app/Chart.yaml")"
  expected=(upgrade --install release oci://ghcr.io/noves-inc/charts/noves-canton-app --version "$default_version" --kube-context target --namespace ns --create-namespace --values "$values")
  [[ "$argv" == "${expected[*]} " ]] || fail "default Helm argv was $argv"
  INSTALLER_LOG="$log" PATH="$bin:$PATH" "$script" --kube-context target --namespace ns --release release --values "$values" --version '4.0.1-alpha.1+build.5'
  argv="$(tr '\n' ' ' <"$log")"
  expected=(upgrade --install release oci://ghcr.io/noves-inc/charts/noves-canton-app --version '4.0.1-alpha.1+build.5' --kube-context target --namespace ns --create-namespace --values "$values")
  [[ "$argv" == "${expected[*]} " ]] || fail "explicit Helm argv was $argv"
}

case "${1:-all}" in
  all) node_config_contracts; compose_contracts; migration_contracts; helm_contracts ;;
  node-config) node_config_contracts ;;
  compose) compose_contracts ;;
  migration) migration_contracts ;;
  helm) helm_contracts ;;
  *) fail "Usage: $0 [all|node-config|compose|migration|helm]" ;;
esac

echo "installer contracts passed"

#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/node-config-upgrade.sh
source "$root/scripts/lib/node-config-upgrade.sh"
# shellcheck source=lib/installation-secrets.sh
source "$root/scripts/lib/installation-secrets.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_file_equals() { cmp -s "$1" "$2" || fail "$1 differs from $2"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain $2"; }
assert_not_contains() { ! grep -Fq -- "$2" "$1" || fail "$1 unexpectedly contains $2"; }
first_line_number() { { grep -Fn -- "$2" "$1" || true; } | head -1 | cut -d: -f1; }
assert_before() {
  local first second
  first="$(first_line_number "$1" "$2")"
  second="$(first_line_number "$1" "$3")"
  [[ -n "$first" && -n "$second" && "$first" -lt "$second" ]] || fail "$1: '$2' does not precede '$3'"
}
assert_installation_secret() {
  [[ -f "$1" && ! -L "$1" ]] || fail "$1 is not a regular file"
  [[ "$(wc -c <"$1" | tr -d ' ')" == 44 ]] || fail "$1 is not 44 bytes"
  grep -Eqx '[A-Za-z0-9+/]{43}=' "$1" || fail "$1 is not the base64 encoding of 32 bytes"
}

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

run_compose_installer() {
  local install_dir="$1" log="$2" bin="$3" output="$4"
  : >"$log"
  INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >"$output" 2>&1
}

installation_secret_contracts() {
  local install_dir="$1" log="$2" bin="$3"
  local state="$install_dir/docker-compose/.state" kek_before canary_before file
  local kek="$state/installation-kek" backend="$state/installation-canary-backend" frontend="$state/installation-canary-frontend"

  assert_installation_secret "$kek"
  assert_installation_secret "$backend"
  assert_installation_secret "$frontend"
  cmp -s "$backend" "$frontend" || fail "the backend and frontend canary copies differ"
  ! cmp -s "$kek" "$backend" || fail "the KEK and the canary share a value"
  [[ -f "$state/installation-kek.created" ]] || fail "the installer did not record that it provisioned the KEK"
  for file in "$kek" "$backend" "$frontend"; do
    [[ "$(node_config_file_mode "$file")" == 600 ]] || fail "$file was not created owner-only"
  done
  assert_contains "$log" 'docker run --rm --network none --user 0:0'
  assert_contains "$log" '/.state/installation-kek:/state/installation-kek'
  assert_contains "$log" '/.state/installation-canary-backend:/state/installation-canary-backend'
  assert_contains "$log" '/.state/installation-canary-frontend:/state/installation-canary-frontend'
  assert_not_contains "$log" '/.state:/state'
  assert_contains "$log" 'run --rm --no-deps --entrypoint /bin/sh backend'
  assert_contains "$log" 'run --rm --no-deps --entrypoint /bin/sh frontend'
  assert_before "$log" ' compose --env-file .env -f compose.yaml pull' 'compose.yaml stop backend frontend'
  assert_before "$log" 'compose.yaml stop backend frontend' 'installation-kek:/state/installation-kek --volume'
  assert_before "$log" '/state/installation-kek' 'entrypoint /bin/sh frontend'
  assert_before "$log" 'entrypoint /bin/sh frontend' 'compose.yaml up -d'
  assert_contains "$log" 'docker compose --env-file .env -f compose.yaml up -d --force-recreate backend frontend'

  # Rerun: the KEK is never regenerated, the canary is replaced, and both copies stay identical.
  kek_before="$(cat "$kek")"
  canary_before="$(cat "$backend")"
  run_compose_installer "$install_dir" "$log" "$bin" "$scratch/rerun.out" || { cat "$scratch/rerun.out" >&2; fail "rerun failed"; }
  [[ "$(cat "$kek")" == "$kek_before" ]] || fail "a rerun regenerated the installation KEK"
  [[ "$(cat "$backend")" != "$canary_before" ]] || fail "a rerun kept the canary capability"
  cmp -s "$backend" "$frontend" || fail "the rerun canary copies differ"
  assert_installation_secret "$backend"

  # A run that fails before the readers are stopped leaves the published canary untouched.
  canary_before="$(cat "$backend")"
  : >"$log"
  if FAKE_DOCKER_FAIL='compose.yaml pull' INSTALLER_LOG="$log" PATH="$bin:$PATH" \
    "$root/scripts/install-compose.sh" --directory "$install_dir" >"$scratch/pull-fail.out" 2>&1; then
    fail "the installer succeeded although the pull failed"
  fi
  [[ "$(cat "$backend")" == "$canary_before" && "$(cat "$frontend")" == "$canary_before" ]] ||
    fail "a failed run replaced the canary while the containers kept the previous one"

  # The KEK is created only if absent: an existing file is never replaced, even by a racing installer.
  printf '%s' "$kek_before" >"$scratch/existing-kek"
  if create_installation_secret_file_exclusive "$scratch/existing-kek" 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='; then
    fail "exclusive creation replaced an existing KEK"
  fi
  [[ "$(cat "$scratch/existing-kek")" == "$kek_before" ]] || fail "exclusive creation changed an existing KEK"
  [[ -z "$(find "$scratch" -maxdepth 1 -name '.installation-secret.*' -print -quit)" ]] || fail "exclusive creation left a temporary file"

  # A malformed retained KEK is refused before stopping the app and is never rewritten.
  printf 'short' >"$kek"
  if run_compose_installer "$install_dir" "$log" "$bin" "$scratch/invalid-kek.out"; then fail "malformed KEK accepted"; fi
  assert_not_contains "$log" 'stop backend frontend'
  printf '%s\n' "$kek_before" >"$kek"
  if run_compose_installer "$install_dir" "$log" "$bin" "$scratch/newline-kek.out"; then fail "45-byte KEK accepted"; fi
  assert_not_contains "$log" 'stop backend frontend'
  printf 'short' >"$kek"
  [[ "$(cat "$kek")" == short ]] || fail "the installer rewrote a retained KEK"
  printf '%s' "$kek_before" >"$kek"

  # Lost KEK next to a retained installation: refused, nothing started.
  rm -f "$kek"
  if run_compose_installer "$install_dir" "$log" "$bin" "$scratch/lost-kek.out"; then
    fail "the installer replaced a lost installation KEK"
  fi
  assert_contains "$scratch/lost-kek.out" 'installation-kek.created'
  [[ ! -e "$kek" ]] || fail "the installer created a KEK after refusing"
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml pull'

  # Restored KEK: reused as is.
  printf '%s' "$kek_before" >"$kek"
  chmod 600 "$kek"
  run_compose_installer "$install_dir" "$log" "$bin" "$scratch/restored.out" || { cat "$scratch/restored.out" >&2; fail "restored KEK run failed"; }
  [[ "$(cat "$kek")" == "$kek_before" ]] || fail "the installer replaced a restored KEK"

  # A symlinked provisioning record is refused before anything is generated.
  ln -s "$scratch/no-such-record" "$state/installation-kek.created.link"
  mv "$state/installation-kek.created" "$scratch/record.saved"
  mv "$state/installation-kek.created.link" "$state/installation-kek.created"
  if run_compose_installer "$install_dir" "$log" "$bin" "$scratch/record-link.out"; then
    fail "the installer accepted a symlinked provisioning record"
  fi
  assert_contains "$scratch/record-link.out" 'symbolic link'
  [[ ! -e "$scratch/no-such-record" ]] || fail "the installer wrote through the record symlink"
  rm -f "$state/installation-kek.created"
  mv "$scratch/record.saved" "$state/installation-kek.created"

  # A concurrent installer holds the installation lock: the second run stops before touching the
  # installation files the first run is parsing and starting, and before touching secrets.
  mkdir "$state/.install.lock"
  canary_before="$(cat "$backend")"
  printf '%s\n' 'held-by-the-running-installer' >"$install_dir/docker-compose/compose.yaml"
  printf '%s\n' 'held-by-the-running-installer' >"$install_dir/docker-compose/config/storage.env.example"
  if run_compose_installer "$install_dir" "$log" "$bin" "$scratch/locked.out"; then
    fail "the installer ran while another held the installation lock"
  fi
  assert_contains "$scratch/locked.out" '.install.lock'
  [[ "$(cat "$install_dir/docker-compose/compose.yaml")" == held-by-the-running-installer ]] ||
    fail "a locked-out run replaced compose.yaml"
  [[ "$(cat "$install_dir/docker-compose/config/storage.env.example")" == held-by-the-running-installer ]] ||
    fail "a locked-out run replaced storage.env.example"
  [[ "$(cat "$backend")" == "$canary_before" ]] || fail "a locked-out run replaced the canary"
  assert_not_contains "$log" 'compose.yaml pull'
  rmdir "$state/.install.lock"
  run_compose_installer "$install_dir" "$log" "$bin" "$scratch/unlocked.out" || { cat "$scratch/unlocked.out" >&2; fail "run after unlock failed"; }
  [[ ! -e "$state/.install.lock" ]] || fail "the installer left its lock behind"

  # Deliberate reset after discarding the database: removing the record allows a new KEK.
  rm -f "$kek" "$state/installation-kek.created"
  run_compose_installer "$install_dir" "$log" "$bin" "$scratch/reset.out" || { cat "$scratch/reset.out" >&2; fail "reset run failed"; }
  assert_installation_secret "$kek"
  [[ "$(cat "$kek")" != "$kek_before" ]] || fail "the reset reused the old KEK"
}

# The Compose file mounts each secret file read-only into exactly the container that reads it. Uses the
# local docker compose parser only; nothing is pulled or started.
compose_file_contracts() {
  local dir="$scratch/compose-file"
  command -v docker >/dev/null 2>&1 || fail "docker is required for compose-file"
  mkdir -p "$dir/.state"
  cp "$root/docker-compose/compose.yaml" "$dir/compose.yaml"
  cp "$root/docker-compose/.env.example" "$dir/.env"
  : >"$dir/.state/accounting.env"
  (cd "$dir" && docker compose --env-file .env -f compose.yaml config --format json) >"$scratch/compose.json" ||
    fail "compose config failed"
  jq -e '
    def secret_binds($service):
      [.services[$service].volumes[]? | select(.type == "bind") |
        {source: (.source | split("/") | last), target, read_only, create: .bind.create_host_path} |
        select(.source | startswith("installation-"))];
    secret_binds("backend") == [
      {source: "installation-kek", target: "/installation-secrets/kek", read_only: true, create: false},
      {source: "installation-canary-backend", target: "/installation-secrets/canary-capability", read_only: true, create: false}
    ] and
    secret_binds("frontend") == [
      {source: "installation-canary-frontend", target: "/installation-secrets/canary-capability", read_only: true, create: false}
    ] and
    secret_binds("database") == [] and
    .services.backend.environment.INSTALLATION_KEK_FILE == "/installation-secrets/kek" and
    .services.backend.environment.INSTALLATION_CANARY_CAPABILITY_FILE == "/installation-secrets/canary-capability" and
    .services.frontend.environment.INSTALLATION_CANARY_CAPABILITY_FILE == "/installation-secrets/canary-capability" and
    (.services.frontend.environment | has("INSTALLATION_KEK_FILE") | not) and
    (.services.database.environment | has("INSTALLATION_KEK_FILE") | not)
  ' "$scratch/compose.json" >/dev/null || { jq '.services | map_values({volumes, environment})' "$scratch/compose.json" >&2; fail "compose secret mounts"; }
}

# Runs the installer's root permission step in a local Linux container (real ownership semantics,
# unlike a macOS bind mount), then reads every file as both runtime uids. Needs local Docker and an
# image with setpriv; nothing is pulled.
permission_contracts() {
  local image="${CDA_TEST_LINUX_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}" kek canary other
  command -v docker >/dev/null 2>&1 || fail "docker is required for permissions"
  docker image inspect "$image" >/dev/null 2>&1 || fail "local image $image is required (set CDA_TEST_LINUX_IMAGE)"
  kek="$(openssl rand -base64 32 | tr -d '\n')"
  canary="$(openssl rand -base64 32 | tr -d '\n')"
  other="$(openssl rand -base64 32 | tr -d '\n')"

  # Arguments: KEK, backend canary, frontend canary ("-" leaves a file out). The files start as the
  # installer leaves them on the host: owned by the installing user (root here), mode 0600.
  run_permission_case() {
    docker run --rm --network none --pull never --user 0:0 \
      --env CASE_KEK="$1" --env CASE_BACKEND="$2" --env CASE_FRONTEND="$3" \
      --entrypoint /bin/sh "$image" -ec '
        mkdir /state
        [ "$CASE_KEK" = - ] || printf "%s" "$CASE_KEK" >/state/installation-kek
        [ "$CASE_BACKEND" = - ] || printf "%s" "$CASE_BACKEND" >/state/installation-canary-backend
        [ "$CASE_FRONTEND" = - ] || printf "%s" "$CASE_FRONTEND" >/state/installation-canary-frontend
        chmod 0600 /state/*
        sh -ec "$1"
        for file in /state/*; do printf "%s %s\n" "$file" "$(stat -c "%u:%g %a" "$file")"; done
        for uid in 1654 1000; do
          for file in /state/*; do
            if setpriv --reuid "$uid" --regid "$uid" --clear-groups cat "$file" >/dev/null 2>&1; then
              printf "%s reads %s\n" "$uid" "$file"
            fi
          done
        done
      ' sh "$(installation_secret_permission_script)"
  }

  run_permission_case "$kek" "$canary" "$canary" >"$scratch/permissions.out" 2>&1 ||
    { cat "$scratch/permissions.out" >&2; fail "permission step failed"; }
  assert_file_equals "$scratch/permissions.out" <(printf '%s\n' \
    '/state/installation-canary-backend 1654:1654 600' \
    '/state/installation-canary-frontend 1000:1000 600' \
    '/state/installation-kek 1654:1654 600' \
    '1654 reads /state/installation-canary-backend' \
    '1654 reads /state/installation-kek' \
    '1000 reads /state/installation-canary-frontend')

  if run_permission_case "${kek%?}" "$canary" "$canary" >"$scratch/permissions-short.out" 2>&1; then
    fail "a 43-byte KEK passed the permission step"
  fi
  assert_contains "$scratch/permissions-short.out" '.state/installation-kek must contain the base64 encoding of 32 bytes'
  if run_permission_case "$kek"$'\n' "$canary" "$canary" >/dev/null 2>&1; then
    fail "a KEK with a trailing newline passed the permission step"
  fi
  if run_permission_case "$kek" "$canary" "$other" >"$scratch/permissions-mismatch.out" 2>&1; then
    fail "mismatched canary copies passed the permission step"
  fi
  assert_contains "$scratch/permissions-mismatch.out" 'canary copies differ'
  if run_permission_case "$kek" "$canary" - >"$scratch/permissions-missing.out" 2>&1; then
    fail "a missing frontend canary passed the permission step"
  fi
  assert_contains "$scratch/permissions-missing.out" '.state/installation-canary-frontend is missing'
}

compose_contracts() {
  local bin="$scratch/compose-bin" log="$scratch/compose.log" install_dir="$scratch/compose-install"
  mkdir "$bin"
cat >"$bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$INSTALLER_LOG"
if [[ "$*" == *'Validate retained KEK before stopping readers.'* ]]; then
  kek=".state/installation-kek"
  [[ "$(wc -c <"$kek" | tr -d ' ')" == 44 ]] && grep -Eqx '[A-Za-z0-9+/]{43}=' "$kek" || exit 1
fi
if [[ -n "${FAKE_DOCKER_FAIL:-}" && "docker $*" == *"$FAKE_DOCKER_FAIL"* ]]; then exit 1; fi
case "$1 $2" in
  'compose version') exit 0 ;;
  'network inspect') exit 0 ;;
esac
if [[ "$1 $2" == 'compose --env-file' && " $* " == *' config --format json '* ]]; then
  python3 - <<'PYDOCKER'
import json,pathlib
pins=dict(line.split('=',1) for line in pathlib.Path('.env').read_text().splitlines() if '=' in line)
services={kind.lower():{'image':pins[kind+'_IMAGE']} for kind in ('BACKEND','FRONTEND','DATABASE')}
services['backend']['volumes']=[{'type':'volume','target':'/exports','source':'exports'}]
print(json.dumps({'services':services,'volumes':{'exports':{'name':'exports'}}}))
PYDOCKER
fi
exit 0
EOF
  cat >"$bin/openssl" <<'EOF'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >>"$INSTALLER_LOG"
counter_file="$(dirname "$INSTALLER_LOG")/openssl.counter"
counter=$(( $(cat "$counter_file" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$counter" >"$counter_file"
printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%02d=' "$((counter % 100))"
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
  installation_secret_contracts "$install_dir" "$log" "$bin"

  # A failure after stopping readers cannot silently restart either with a partly rotated capability.
  local failure_stage
  for failure_stage in 'installation-kek:/state/installation-kek --volume' 'run --rm --no-deps --entrypoint /bin/sh frontend'; do
    : >"$log"
    if FAKE_DOCKER_FAIL="$failure_stage" INSTALLER_LOG="$log" PATH="$bin:$PATH" \
      "$root/scripts/install-compose.sh" --directory "$install_dir" >"$scratch/stopped-failure.out" 2>&1; then
      fail "installer accepted failed secret preparation: $failure_stage"
    fi
    assert_contains "$scratch/stopped-failure.out" 'backend and frontend may remain stopped or partly recreated'
    assert_contains "$scratch/stopped-failure.out" 'rerun the same installer command'
    assert_not_contains "$log" 'up -d'
    [[ ! -e "$install_dir/docker-compose/.state/.install.lock" ]] || fail 'failed stopped upgrade retained its lock'
  done

  # A relative --directory resolves once, before the lock is taken: the lock is released after the
  # installer changes directory, so consecutive runs both succeed and none leaves the lock behind.
  local run
  for run in 1 2; do
    (cd "$(dirname "$install_dir")" &&
      run_compose_installer "$(basename "$install_dir")" "$log" "$bin" "$scratch/relative-$run.out") ||
      { cat "$scratch/relative-$run.out" >&2; fail "relative --directory run $run failed"; }
    [[ ! -e "$install_dir/docker-compose/.state/.install.lock" ]] ||
      fail "relative --directory run $run left the installation lock behind"
  done

  rm -rf "$install_dir"
  write_compose_fixture "$install_dir"
  printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001"}}}' >"$install_dir/docker-compose/.state/nodes-config.json"
  printf '%s\n' 'must-remain' >"$scratch/kek-symlink-target"
  ln -s "$scratch/kek-symlink-target" "$install_dir/docker-compose/.state/installation-kek"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >"$scratch/kek-symlink.out" 2>&1; then
    fail "installer accepted a symlinked installation KEK"
  fi
  assert_contains "$scratch/kek-symlink.out" 'symbolic link'
  [[ "$(cat "$scratch/kek-symlink-target")" == must-remain ]] || fail "installer wrote through the KEK symlink"
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml pull'

  rm -rf "$install_dir"
  write_compose_fixture "$install_dir"
  printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001"}}}' >"$install_dir/docker-compose/.state/nodes-config.json"
  mkdir -p "$install_dir/docker-compose/.state/installation-canary-frontend"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/install-compose.sh" --directory "$install_dir" >"$scratch/canary-dir.out" 2>&1; then
    fail "installer accepted a directory in place of the frontend canary file"
  fi
  assert_contains "$scratch/canary-dir.out" 'regular file'
  assert_not_contains "$log" 'compose --env-file .env -f compose.yaml pull'

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
if [[ " $* " == *' config --format json '* ]]; then
  python3 - <<'PYDOCKER'
import json,pathlib
pins=dict(line.split('=',1) for line in pathlib.Path('.env').read_text().splitlines() if '=' in line)
services={kind.lower():{'image':pins[kind+'_IMAGE']} for kind in ('BACKEND','FRONTEND','DATABASE')}
services['backend']['volumes']=[{'type':'volume','target':'/exports','source':'exports'}]
print(json.dumps({'services':services,'volumes':{'exports':{'name':'exports'}}}))
PYDOCKER
fi
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
  assert_installation_secret "$compose_dir/.state/installation-kek"
  assert_installation_secret "$compose_dir/.state/installation-canary-backend"
  cmp -s "$compose_dir/.state/installation-canary-backend" "$compose_dir/.state/installation-canary-frontend" ||
    fail "migration wrapper wrote different canary copies"
  assert_contains "$log" 'docker run --rm --network none --user 0:0'
  assert_before "$log" '/state/installation-kek' 'compose.migrate-v3.yaml run --rm --no-deps --entrypoint /bin/sh frontend'
  assert_before "$log" 'entrypoint /bin/sh frontend' 'compose.migrate-v3.yaml up -d'
  assert_before "$log" 'compose.migrate-v3.yaml stop backend frontend' 'installation-kek:/state/installation-kek --volume'
  assert_contains "$log" 'compose.migrate-v3.yaml up -d --force-recreate backend frontend'

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

  # A concurrent installer holds the installation lock: the migration stops before rewriting the
  # retained node configuration or touching Docker.
  write_migration_fixture
  printf '%s\n' '{"nodes":{"main-node":{"addr":"participant:5001","expected_synchronizer_id":" ","m2mIndexing":{"static_token_file":"/m2m-indexing-secrets/main-node/token"}}}}' >"$compose_dir/.state/nodes-config.json"
  cp "$compose_dir/.state/nodes-config.json" "$scratch/migration-locked-nodes.json"
  mkdir "$compose_dir/.state/.install.lock"
  : >"$log"
  if INSTALLER_LOG="$log" PATH="$bin:$PATH" "$root/scripts/migrate-v3.sh" \
    --source-version 3.16.1 --backup-confirmed --old-workload-stopped \
    --volume v3-database --directory "$compose_dir" >"$scratch/migration-locked.out" 2>&1; then
    fail "migration wrapper ran while another installer held the installation lock"
  fi
  assert_contains "$scratch/migration-locked.out" '.install.lock'
  assert_file_equals "$compose_dir/.state/nodes-config.json" "$scratch/migration-locked-nodes.json"
  [[ ! -s "$log" ]] || fail "migration wrapper started Docker while another installer held the lock"
  rmdir "$compose_dir/.state/.install.lock"
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
  all) node_config_contracts; compose_contracts; migration_contracts; helm_contracts; compose_file_contracts; permission_contracts ;;
  fake-docker) node_config_contracts; compose_contracts; migration_contracts; helm_contracts ;;
  node-config) node_config_contracts ;;
  compose) compose_contracts ;;
  migration) migration_contracts ;;
  helm) helm_contracts ;;
  compose-file) compose_file_contracts ;;
  permissions) permission_contracts ;;
  local-docker) compose_file_contracts; permission_contracts ;;
  *) fail "Usage: $0 [all|fake-docker|node-config|compose|migration|helm|compose-file|permissions|local-docker]" ;;
esac

echo "installer contracts passed"

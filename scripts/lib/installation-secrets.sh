#!/usr/bin/env bash

# Per-installation credential secrets for Compose.
#
# .state/installation-kek is the key-encryption key for the installation's private signing key, which
# the backend stores encrypted in the database. It is generated once and never regenerated: a new value
# on a database that already holds installation material leaves the backend unable to use its
# credential. .state/installation-kek.created records that this installation has a KEK, so a KEK that
# disappears later is reported as lost instead of silently replaced. Removing that record is the
# operator's deliberate statement that the database was discarded too.
#
# The canary capability authorizes the frontend's server-side canary call to the backend. It carries no
# stored state, so every installer run writes a new value. The backend and the frontend run as
# different uids and each file must be owner-only, so the same value is written as two copies, one per
# container.
#
# Every file holds exactly 44 bytes: the base64 encoding of 32 random bytes, with no newline.

installation_secret_backend_uid=1654
installation_secret_frontend_uid=1000

installation_secret_names=(installation-kek installation-canary-backend installation-canary-frontend)

new_installation_secret_value() {
  local value
  value="$(openssl rand -base64 32 | tr -d '\n')" || return 1
  if [[ ! "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    printf 'openssl did not return the base64 encoding of 32 bytes.\n' >&2
    return 1
  fi
  printf '%s' "$value"
}

# Writes the value to a private temporary file in the same directory and renames it into place, so a
# reader never sees a partial file and a retained file owned by a container uid is replaced, not edited.
write_installation_secret_file() {
  local path="$1" value="$2" temporary
  temporary="$(umask 077 && mktemp "$(dirname "$path")/.installation-secret.XXXXXX")" || return 1
  if ! { chmod 600 "$temporary" && printf '%s' "$value" >"$temporary" && mv -f "$temporary" "$path"; }; then
    rm -f "$temporary"
    return 1
  fi
}

generate_installation_secret_files() {
  local state_dir="$1" name path value
  local kek="$state_dir/installation-kek" record="$state_dir/installation-kek.created"

  for name in "${installation_secret_names[@]}"; do
    path="$state_dir/$name"
    if [[ -L "$path" ]]; then
      printf 'Installation secret must be a regular file, not a symbolic link: %s\n' "$path" >&2
      return 1
    fi
    if [[ -e "$path" && ! -f "$path" ]]; then
      printf 'Installation secret must be a regular file: %s\n' "$path" >&2
      return 1
    fi
  done

  if [[ ! -e "$kek" ]]; then
    if [[ -e "$record" ]]; then
      printf '%s\n' \
        "$kek is missing, but $record shows this installation already had one." \
        'A new key would leave the installation credential stored in the database unusable.' \
        "Restore $kek from the backup taken with the database. If the database was discarded" \
        "as well, delete $record to provision a new key." >&2
      return 1
    fi
    value="$(new_installation_secret_value)" || return 1
    write_installation_secret_file "$kek" "$value" || return 1
  fi
  if [[ ! -e "$record" ]]; then
    printf 'The installation KEK in installation-kek was provisioned for this installation. Back it up with the database.\n' \
      >"$record" || return 1
  fi

  value="$(new_installation_secret_value)" || return 1
  write_installation_secret_file "$state_dir/installation-canary-backend" "$value" || return 1
  write_installation_secret_file "$state_dir/installation-canary-frontend" "$value" || return 1
}

# POSIX sh run as root in a one-shot container with the three files mounted under /state. It checks the
# format, assigns each file to the uid of the only container that mounts it with mode 0600, and proves
# the result from inside a container, which is the view the runtime containers get.
installation_secret_permission_script() {
  cat <<EOF
set -eu
fail() { echo "\$*" >&2; exit 1; }
check_format() {
  [ -f "/state/\$1" ] || fail ".state/\$1 is missing."
  if [ "\$(wc -c <"/state/\$1" | tr -d ' ')" != 44 ] || ! grep -Eqx '[A-Za-z0-9+/]{43}=' "/state/\$1"; then
    fail ".state/\$1 must contain the base64 encoding of 32 bytes: 44 characters and no newline."
  fi
}
assign() {
  chown "\$2:\$2" "/state/\$1"
  chmod 0600 "/state/\$1"
  [ "\$(stat -c '%u:%g %a' "/state/\$1")" = "\$2:\$2 600" ] || fail ".state/\$1 is not owned by \$2 with mode 0600."
}
check_format installation-kek
check_format installation-canary-backend
check_format installation-canary-frontend
[ "\$(cat /state/installation-canary-backend)" = "\$(cat /state/installation-canary-frontend)" ] ||
  fail "The backend and frontend canary copies differ."
assign installation-kek $installation_secret_backend_uid
assign installation-canary-backend $installation_secret_backend_uid
assign installation-canary-frontend $installation_secret_frontend_uid
EOF
}

secure_installation_secret_files() {
  local env_file="$1" compose_file="$2" state_dir="$3"
  local backend_image name mounts=()

  backend_image="$(
    docker compose --env-file "$env_file" -f "$compose_file" \
      config --format json | jq -er '.services.backend.image'
  )" || return 1
  for name in "${installation_secret_names[@]}"; do
    mounts+=(--volume "$state_dir/$name:/state/$name")
  done
  docker run --rm --network none --user 0:0 "${mounts[@]}" \
    --entrypoint /bin/sh "$backend_image" -ec "$(installation_secret_permission_script)"
}

# Proves each runtime container can read its own files under its image user, and that the frontend has
# no KEK. Arguments: the env file, then the Compose file arguments the application is started with.
verify_installation_secret_access() {
  local env_file="$1"
  shift
  docker compose --env-file "$env_file" "$@" run --rm --no-deps --entrypoint /bin/sh backend -ec \
    'test -r "$INSTALLATION_KEK_FILE" && test -s "$INSTALLATION_KEK_FILE" && test -r "$INSTALLATION_CANARY_CAPABILITY_FILE"' ||
    return 1
  docker compose --env-file "$env_file" "$@" run --rm --no-deps --entrypoint /bin/sh frontend -ec \
    'test -r "$INSTALLATION_CANARY_CAPABILITY_FILE" && test -s "$INSTALLATION_CANARY_CAPABILITY_FILE" && test ! -e /installation-secrets/kek'
}

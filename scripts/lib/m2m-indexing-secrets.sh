#!/usr/bin/env bash

m2m_indexing_secret_container_paths=()

validate_m2m_indexing_env_file() {
  local file="$1" key
  for key in M2M_TOKEN_ENDPOINT M2M_CLIENT_ID M2M_CLIENT_SECRET M2M_AUDIENCE; do
    if ! grep -Eq "^${key}=(\"[^\"]+\"|[^[:space:]].*)$" "$file" 2>/dev/null ||
      grep -Eq "^${key}=\"?replace-with-" "$file" 2>/dev/null; then
      printf '%s must contain a non-blank, non-placeholder %s.\n' "$file" "$key" >&2
      return 1
    fi
  done
}

validate_m2m_indexing_configuration() {
  local nodes_file="$1" global_env_file="$2" nodes_without_explicit_m2m_indexing
  nodes_without_explicit_m2m_indexing="$(jq -r '
    .nodes | to_entries[] |
    select((.value.m2mIndexing? | type) != "object") | .key
  ' "$nodes_file")" || return 1
  if [[ -z "$nodes_without_explicit_m2m_indexing" ]]; then
    return 0
  fi

  if [[ ! -f "$global_env_file" ]]; then
    printf 'Create %s for global M2M indexing, or configure explicit M2M indexing credentials for: %s\n' \
      "$global_env_file" "$(tr '\n' ' ' <<<"$nodes_without_explicit_m2m_indexing")" >&2
    return 1
  fi
  validate_m2m_indexing_env_file "$global_env_file"
}

require_real_m2m_indexing_secret_root() {
  local m2m_indexing_root="$1" root_without_trailing_slash
  root_without_trailing_slash="${m2m_indexing_root%/}"
  [[ -n "$root_without_trailing_slash" ]] || root_without_trailing_slash="/"
  if [[ ! -d "$m2m_indexing_root" || -L "$m2m_indexing_root" || -L "$root_without_trailing_slash" ]]; then
    printf 'M2M indexing secret root must be a real directory, not a symbolic link: %s\n' "$m2m_indexing_root" >&2
    return 1
  fi
}

validate_m2m_indexing_secret_files() {
  local nodes_file="$1"
  local m2m_indexing_root="$2"
  local node_id setting container_path relative_path host_path root_real parent_real

  m2m_indexing_secret_container_paths=()
  jq -e '
    .nodes != null and (.nodes | type == "object") and
    all(.nodes | to_entries[];
      (.value.m2mIndexing? == null) or
      ((.value.m2mIndexing | type == "object") and
       (((.value.m2mIndexing.client_secret_file? // "") != "") !=
        ((.value.m2mIndexing.static_token_file? // "") != ""))))
  ' "$nodes_file" >/dev/null || {
    printf 'Each explicit node M2M indexing setting must contain exactly one secret-file source.\n' >&2
    return 1
  }

  if ! jq -e '[.nodes[].m2mIndexing? | select(
      type == "object" and
      (((.client_secret_file? // "") != "") or ((.static_token_file? // "") != ""))
    )] | length > 0' "$nodes_file" >/dev/null; then
    return 0
  fi

  require_real_m2m_indexing_secret_root "$m2m_indexing_root" || return 1

  root_real="$(cd "$m2m_indexing_root" 2>/dev/null && pwd -P)" || {
    printf 'M2M indexing secret directory is missing or unreadable: %s\n' "$m2m_indexing_root" >&2
    return 1
  }

  while IFS=$'\t' read -r node_id setting container_path; do
    [[ -n "$container_path" ]] || continue
    if [[ "$container_path" != /m2m-indexing-secrets/* ]]; then
      printf "Node '%s' setting '%s' must use a path below /m2m-indexing-secrets: %s\n" \
        "$node_id" "$setting" "$container_path" >&2
      return 1
    fi

    relative_path="${container_path#/m2m-indexing-secrets/}"
    if [[ -z "$relative_path" || "/$relative_path/" == *"/../"* || "/$relative_path/" == *"/./"* ]]; then
      printf "Node '%s' setting '%s' contains an invalid M2M indexing secret path: %s\n" \
        "$node_id" "$setting" "$container_path" >&2
      return 1
    fi

    host_path="$m2m_indexing_root/$relative_path"
    parent_real="$(cd "$(dirname "$host_path")" 2>/dev/null && pwd -P)" || true
    if [[ -z "$parent_real" || ( "$parent_real" != "$root_real" && "$parent_real" != "$root_real/"* ) ||
          ! -f "$host_path" || -L "$host_path" || ! -r "$host_path" ]]; then
      printf "Node '%s' setting '%s' is missing, unreadable, or unsafe: %s\n" \
        "$node_id" "$setting" "$container_path" >&2
      return 1
    fi
    m2m_indexing_secret_container_paths+=("$container_path")
  done < <(jq -r '
    .nodes | to_entries[] |
    .key as $node_id |
    .value.m2mIndexing? as $m2m_indexing |
    select($m2m_indexing != null) |
    [
      ["client_secret_file", ($m2m_indexing.client_secret_file // "")],
      ["static_token_file", ($m2m_indexing.static_token_file // "")]
    ][] |
    select(.[1] != "") |
    [$node_id, .[0], .[1]] | @tsv
  ' "$nodes_file")
}

secure_m2m_indexing_secret_files() {
  local env_file="$1"
  local compose_file="$2"
  local m2m_indexing_root="$3"
  shift 3

  (($#)) || return 0

  local backend_image
  backend_image="$(
    docker compose --env-file "$env_file" -f "$compose_file" \
      config --format json | jq -er '.services.backend.image'
  )" || return 1

  require_real_m2m_indexing_secret_root "$m2m_indexing_root" || return 1
  docker run --rm --user 0:0 \
    --volume "$m2m_indexing_root:/m2m-indexing-secrets" \
    --entrypoint /bin/sh "$backend_image" -ec '
      chgrp 1654 /m2m-indexing-secrets
      chmod 0750 /m2m-indexing-secrets
      for secret_path do
        parent_path="$(dirname "$secret_path")"
        while [ "$parent_path" != /m2m-indexing-secrets ]; do
          chgrp 1654 "$parent_path"
          chmod 0750 "$parent_path"
          parent_path="$(dirname "$parent_path")"
        done
        chgrp 1654 "$secret_path"
        chmod 0440 "$secret_path"
      done
    ' sh "$@"
}

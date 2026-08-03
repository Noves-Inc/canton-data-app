#!/usr/bin/env bash

compose_export_volume_name() {
  local compose_json="$1"
  local logical_name

  logical_name="$(jq -er '
    .services.backend.volumes[] |
    select(.type == "volume" and .target == "/exports") |
    .source
  ' "$compose_json")" || return 1

  jq -er --arg logical_name "$logical_name" \
    '.volumes[$logical_name].name // $logical_name' "$compose_json"
}

prepare_export_volume() {
  local env_file="$1"
  local compose_file="$2"
  local compose_json backend_image exports_volume

  compose_json="$(mktemp)" || return 1
  if ! docker compose --env-file "$env_file" -f "$compose_file" \
      config --format json >"$compose_json"; then
    rm -f "$compose_json"
    return 1
  fi

  backend_image="$(jq -er '.services.backend.image' "$compose_json")" || {
    rm -f "$compose_json"
    return 1
  }
  exports_volume="$(compose_export_volume_name "$compose_json")" || {
    rm -f "$compose_json"
    return 1
  }
  rm -f "$compose_json"

  docker volume create "$exports_volume" >/dev/null || return 1
  docker run --rm --user 0:0 \
    --volume "$exports_volume:/exports" \
    --entrypoint /bin/sh "$backend_image" -ec '
      mkdir -p /exports/accounting
      chown -R 1654:1654 /exports
      chmod 0770 /exports /exports/accounting
    '
}

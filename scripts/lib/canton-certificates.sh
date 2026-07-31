#!/usr/bin/env bash

canton_certificate_container_paths=()

validate_canton_certificate_files() {
  local nodes_file="$1"
  local certificate_root="$2"
  local node_id setting container_path relative_path host_path

  canton_certificate_container_paths=()
  jq -e '
    .nodes != null and
    (.nodes | type == "object") and
    all(.nodes | to_entries[];
      ((.value.client_cert_file // "") == "") ==
      ((.value.client_key_file // "") == ""))
  ' "$nodes_file" >/dev/null || {
    printf 'The nodes config must contain nodes, and each client certificate and private key must be configured together.\n' >&2
    return 1
  }

  while IFS=$'\t' read -r node_id setting container_path; do
    [[ -n "$container_path" ]] || continue
    if [[ "$container_path" != /certificates/* ]]; then
      printf "Node '%s' setting '%s' must use a path below /certificates: %s\n" \
        "$node_id" "$setting" "$container_path" >&2
      return 1
    fi

    relative_path="${container_path#/certificates/}"
    if [[ -z "$relative_path" || "/$relative_path/" == *"/../"* ]]; then
      printf "Node '%s' setting '%s' contains an invalid certificate path: %s\n" \
        "$node_id" "$setting" "$container_path" >&2
      return 1
    fi

    host_path="$certificate_root/$relative_path"
    if [[ ! -f "$host_path" || ! -r "$host_path" ]]; then
      printf "Node '%s' setting '%s' is missing or unreadable: %s\n" \
        "$node_id" "$setting" "$container_path" >&2
      return 1
    fi
    canton_certificate_container_paths+=("$container_path")
  done < <(jq -r '
    .nodes | to_entries[] |
    .key as $node_id |
    .value as $node |
    [
      ["cert_file", ($node.cert_file // "")],
      ["client_cert_file", ($node.client_cert_file // "")],
      ["client_key_file", ($node.client_key_file // "")]
    ][] |
    select(.[1] != "") |
    [$node_id, .[0], .[1]] | @tsv
  ' "$nodes_file")
}

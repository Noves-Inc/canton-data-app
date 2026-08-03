#!/usr/bin/env bash

node_config_file_mode() {
  local file="$1" mode
  if mode="$(stat -f '%Lp' "$file" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return 0
  fi
  if mode="$(stat -c '%a' "$file" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return 0
  fi
  printf 'Could not read file mode: %s\n' "$file" >&2
  return 1
}

valid_nodes_config_json() {
  jq -e 'type == "object" and (.nodes | type == "object")' "$1" >/dev/null
}

upgrade_nodes_config_file() (
  local config_file="$1" backup="${1}.pre-retired-field-upgrade.bak"
  local backup_tmp="" rewrite_tmp="" mode config_dir
  trap '[[ -z "${backup_tmp:-}" ]] || rm -f -- "$backup_tmp"; [[ -z "${rewrite_tmp:-}" ]] || rm -f -- "$rewrite_tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  valid_nodes_config_json "$config_file" || {
    echo "Invalid nodes configuration: $config_file" >&2; return 1; }
  local nonempty
  nonempty="$(jq -r '
    .nodes | to_entries[] |
    select(
      (.value | type == "object") and
      (.value | has("expected_synchronizer_id")) and
      (.value.expected_synchronizer_id |
        if . == null then false
        elif type == "string" then test("\\S")
        else true
        end)
    ) | .key
  ' "$config_file")"
  if [[ -n "$nonempty" ]]; then
    while IFS= read -r node; do
      [[ -z "$node" ]] || echo "Node '$node' has expected_synchronizer_id; remove the retired field after selecting synchronizer_alias explicitly." >&2
    done <<<"$nonempty"
    return 1
  fi
  jq -e '[.nodes[] | select(
    type == "object" and has("expected_synchronizer_id") and
    (.expected_synchronizer_id | . == null or (type == "string" and test("^\\s*$")))
  )] | length > 0' "$config_file" >/dev/null || return 0
  mode="$(node_config_file_mode "$config_file")" || return 1
  config_dir="$(dirname "$config_file")"
  if [[ -e "$backup" || -L "$backup" ]]; then
    if [[ ! -f "$backup" || -L "$backup" ]] || ! valid_nodes_config_json "$backup"; then
      printf 'Existing node configuration backup is unsuitable: %s\n' "$backup" >&2
      return 1
    fi
  else
    backup_tmp="$(mktemp "$config_dir/.nodes-config-backup.XXXXXX")" || return 1
    if ! cp -p "$config_file" "$backup_tmp" || ! valid_nodes_config_json "$backup_tmp"; then
      printf 'Could not create a validated node configuration backup: %s\n' "$backup" >&2
      return 1
    fi
    chmod "$mode" "$backup_tmp" || return 1
    mv -f "$backup_tmp" "$backup" || return 1
    backup_tmp=""
  fi
  rewrite_tmp="$(mktemp "$config_dir/.nodes-config-upgrade.XXXXXX")" || return 1
  jq 'del(.nodes[] | select(
    type == "object" and has("expected_synchronizer_id") and
    (.expected_synchronizer_id | . == null or (type == "string" and test("^\\s*$")))
  ) | .expected_synchronizer_id)' "$config_file" >"$rewrite_tmp" || return 1
  chmod "$mode" "$rewrite_tmp" || return 1
  valid_nodes_config_json "$rewrite_tmp" || return 1
  mv -f "$rewrite_tmp" "$config_file" || return 1
  rewrite_tmp=""
)

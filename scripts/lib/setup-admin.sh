#!/usr/bin/env bash

wait_for_setup_health() {
  local origin="$1"
  local attempt
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if curl -fsS "$origin/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Setup service did not become healthy at %s.\n' "$origin" >&2
  return 1
}

bootstrap_helm_setup_admin() (
  set -o pipefail
  local namespace="$1"
  local secret_name="$2"
  local origin="$3"
  local setup_token="$4"

  kubectl --namespace "$namespace" get secret "$secret_name" -o json |
    jq -e --arg participantNamespace "$namespace" '{
      sourceMode: "helm",
      participantNamespace: $participantNamespace,
      discoveryUrl: ((.data.url // "") | @base64d),
      expectedAdministratorUserId: ((.data["ledger-api-user"] // "") | @base64d),
      clientId: ((.data["client-id"] // "") | @base64d),
      clientSecret: ((.data["client-secret"] // "") | @base64d),
      audience: ((.data.audience // "") | @base64d),
      scope: ((.data.scope // "") | @base64d)
    }
    | select(
        .discoveryUrl != ""
        and .expectedAdministratorUserId != ""
        and .clientId != ""
        and .clientSecret != ""
        and .audience != ""
      )' |
    curl -fsS \
      -H "x-noves-setup-bootstrap: $setup_token" \
      -H 'content-type: application/json' \
      --data-binary @- \
      "$origin/internal/setup/admin-credential" >/dev/null
)

bootstrap_compose_setup_admin() (
  set -o pipefail
  local selected_container="$1"
  local origin="$2"
  local setup_token="$3"
  local container="$selected_container"
  local -a matches=()

  if [[ -z "$container" ]]; then
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] && matches+=("$candidate")
    done < <(
      docker ps \
        --filter label=com.docker.compose.service=validator \
        --format '{{.ID}}'
    )
    if ((${#matches[@]} == 0)); then
      printf 'No running Compose validator was found; use manual setup.\n' >&2
      return 1
    fi
    if ((${#matches[@]} > 1)); then
      printf 'Multiple Compose validators were found; pass --validator-container NAME.\n' >&2
      return 1
    fi
    container="${matches[0]}"
  fi

  docker inspect "$container" |
    jq -e '
      .[0] as $container
      | $container.Config.Env
      | map(
          capture(
            "^SPLICE_APP_VALIDATOR_LEDGER_API_AUTH_(?<key>URL|CLIENT_ID|CLIENT_SECRET|AUDIENCE|SCOPE|USER_NAME)=(?<value>.*)$"
          )
          | {key: .key, value: .value}
        )
      | from_entries
      | {
          sourceMode: "compose",
          discoveryUrl: (.URL // ""),
          expectedAdministratorUserId: (.USER_NAME // ""),
          clientId: (.CLIENT_ID // ""),
          clientSecret: (.CLIENT_SECRET // ""),
          audience: (.AUDIENCE // ""),
          scope: (.SCOPE // ""),
          validatorContainer: ($container.Name // ""),
          composeNetwork: (($container.NetworkSettings.Networks // {}) | keys | first // "")
        }
      | select(
          .discoveryUrl != ""
          and .expectedAdministratorUserId != ""
          and .clientId != ""
          and .clientSecret != ""
          and .audience != ""
        )' |
    curl -fsS \
      -H "x-noves-setup-bootstrap: $setup_token" \
      -H 'content-type: application/json' \
      --data-binary @- \
      "$origin/internal/setup/admin-credential" >/dev/null
)

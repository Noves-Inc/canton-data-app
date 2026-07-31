#!/usr/bin/env bash

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required."
}

random_secret() {
  openssl rand -hex 32
}

resolve_noves_gateway_token() {
  local token=""
  local token_file="${NOVES_GATEWAY_AUTH_TOKEN_FILE:-}"

  if [[ "${NOVES_GATEWAY_AUTH_TOKEN:-}" =~ [^[:space:]] ]]; then
    token="$NOVES_GATEWAY_AUTH_TOKEN"
  elif [[ -n "$token_file" ]]; then
    [[ -f "$token_file" && -r "$token_file" ]] ||
      die "NOVES_GATEWAY_AUTH_TOKEN_FILE is not readable: $token_file"
    token="$(<"$token_file")"
  elif { exec 3<>/dev/tty; } 2>/dev/null; then
    IFS= read -r -s -p "Noves gateway credential: " token <&3
    printf '\n' >&3
    exec 3>&-
  else
    die "Set NOVES_GATEWAY_AUTH_TOKEN or NOVES_GATEWAY_AUTH_TOKEN_FILE."
  fi

  [[ "$token" =~ [^[:space:]] ]] ||
    die "The Noves gateway credential is blank."
  printf '%s' "$token"
}


write_private_file() {
  local path="$1"
  umask 077
  mkdir -p "$(dirname "$path")"
  touch "$path"
  chmod 600 "$path"
}

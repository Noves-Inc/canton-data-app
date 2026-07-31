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

write_private_file() {
  local path="$1"
  umask 077
  mkdir -p "$(dirname "$path")"
  touch "$path"
  chmod 600 "$path"
}

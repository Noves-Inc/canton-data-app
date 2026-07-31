#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install.sh helm [installer options]
  install.sh compose [installer options]
EOF
}

case "${1:-}" in
  helm|compose) target="$1"; shift ;;
  -h|--help|"") usage; exit 0 ;;
  *) printf 'Unknown installer: %s\n' "$1" >&2; usage >&2; exit 1 ;;
esac

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
local_installer="$script_root/scripts/install-$target.sh"
if [[ -f "$local_installer" ]]; then
  exec "$local_installer" "$@"
fi

ref="${NOVES_DATA_APP_INSTALL_REF:-v4}"
raw_base="${NOVES_DATA_APP_INSTALL_RAW_BASE:-https://raw.githubusercontent.com/Noves-Inc/canton-data-app/$ref}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/scripts/lib" "$scratch/docker-compose/config"
curl -fsSL "$raw_base/scripts/install-$target.sh" -o "$scratch/scripts/install-$target.sh"
curl -fsSL "$raw_base/scripts/lib/common.sh" -o "$scratch/scripts/lib/common.sh"
if [[ "$target" == compose ]]; then
  for file in compose.yaml compose.migrate-v3.yaml .env.example; do
    curl -fsSL "$raw_base/docker-compose/$file" -o "$scratch/docker-compose/$file"
  done
  curl -fsSL "$raw_base/docker-compose/config/nodes-config.json" \
    -o "$scratch/docker-compose/config/nodes-config.json"
  curl -fsSL "$raw_base/docker-compose/config/storage.env.example" \
    -o "$scratch/docker-compose/config/storage.env.example"
fi
chmod +x "$scratch/scripts/install-$target.sh"
"$scratch/scripts/install-$target.sh" "$@"

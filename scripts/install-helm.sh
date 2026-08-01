#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

chart_ref="oci://ghcr.io/noves-inc/charts/noves-canton-app"
chart_constraint='>=4.0.0 <5.0.0'
namespace="validator"
release="noves-canton-data-app"
values_file=""

usage() {
  cat <<'EOF'
Usage:
  install-helm.sh --values FILE

Options:
  --namespace NAME   Kubernetes namespace (default: validator)
  --release NAME     Helm release name (default: noves-canton-data-app)
  --values FILE      Operator-maintained values file
EOF
}

while (($#)); do
  case "$1" in
    --namespace) namespace="${2:?Missing namespace}"; shift 2 ;;
    --release) release="${2:?Missing release}"; shift 2 ;;
    --values) values_file="${2:?Missing values file}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_command helm

[[ -n "$values_file" ]] || die "--values FILE is required."
[[ -f "$values_file" ]] || die "Values file not found: $values_file"

exec helm upgrade --install "$release" "$chart_ref" \
  --version "$chart_constraint" \
  --namespace "$namespace" \
  --create-namespace \
  --values "$values_file"

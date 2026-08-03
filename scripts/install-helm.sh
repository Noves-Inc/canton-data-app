#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

chart_ref="oci://ghcr.io/noves-inc/charts/noves-canton-app"
chart_version="$(awk '/^version:/{print $2; exit}' "$script_dir/../chart/noves-canton-data-app/Chart.yaml")"
namespace="validator"
release="noves-canton-data-app"
values_file=""
kube_context=""

is_exact_semver() {
  local version="$1" without_build prerelease identifier
  local -a identifiers
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || return 1
  without_build="${version%%+*}"
  [[ "$without_build" == *-* ]] || return 0
  prerelease="${without_build#*-}"
  IFS='.' read -r -a identifiers <<<"$prerelease"
  for identifier in "${identifiers[@]}"; do
    if [[ "$identifier" =~ ^[0-9]+$ && ${#identifier} -gt 1 && "$identifier" == 0* ]]; then
      return 1
    fi
  done
}

usage() {
  cat <<'EOF'
Usage:
  install-helm.sh --kube-context CONTEXT --values FILE

Options:
  --namespace NAME   Kubernetes namespace (default: validator)
  --release NAME     Helm release name (default: noves-canton-data-app)
  --values FILE      Operator-maintained values file
  --version VERSION  Exact OCI chart version (default: checked-out Chart.yaml version)
  --kube-context CONTEXT  Required Kubernetes context
EOF
}

while (($#)); do
  case "$1" in
    --namespace) namespace="${2:?Missing namespace}"; shift 2 ;;
    --release) release="${2:?Missing release}"; shift 2 ;;
    --values) values_file="${2:?Missing values file}"; shift 2 ;;
    --version) chart_version="${2:?Missing version}"; shift 2 ;;
    --kube-context) kube_context="${2:?Missing kube context}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_command helm

[[ -n "$values_file" ]] || die "--values FILE is required."
[[ -f "$values_file" ]] || die "Values file not found: $values_file"
[[ -n "$kube_context" ]] || die "--kube-context CONTEXT is required."
is_exact_semver "$chart_version" || die "--version must be one exact SemVer 2 version."

exec helm upgrade --install "$release" "$chart_ref" \
  --version "$chart_version" \
  --kube-context "$kube_context" \
  --namespace "$namespace" \
  --create-namespace \
  --values "$values_file"

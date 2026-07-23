#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$repo_root/tests/helm-chart.sh"
"$repo_root/tests/docker-compose.sh"
"$repo_root/tests/installers.sh"
"$repo_root/tests/docs.sh"

#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp)"
trap 'rm -f "$scratch"' EXIT

search_paths=(
  "$repo_root/install.sh"
  "$repo_root/scripts"
  "$repo_root/docker-compose"
  "$repo_root/chart"
  "$repo_root/docs"
)

while IFS= read -r markdown; do
  search_paths+=("$markdown")
done < <(
  find "$repo_root" -maxdepth 1 -type f -name '*.md' ! -name 'CLAUDE.md' -print
)

if grep -RInE \
  --exclude-dir=superpowers \
  --exclude='*.png' \
  --exclude='*.jpg' \
  '\bCDA_[A-Z0-9_]+\b' "${search_paths[@]}" >"$scratch"; then
  printf 'Legacy CDA-prefixed environment variables remain:\n' >&2
  cat "$scratch" >&2
  exit 1
fi

for obsolete in \
  MIGRATION_SOURCE_VERSION \
  MIGRATION_BACKUP_CONFIRMED \
  MIGRATION_OLD_WORKLOAD_STOPPED
do
  if grep -RIn "$obsolete" "$repo_root/docker-compose" >"$scratch"; then
    printf 'Unnecessary migration confirmation variable remains:\n' >&2
    cat "$scratch" >&2
    exit 1
  fi
done

if grep -RIn 'CANTON_STREAM_URL' "${search_paths[@]}" >"$scratch"; then
  printf 'Retired streaming sidecar configuration remains:\n' >&2
  cat "$scratch" >&2
  exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

compose_dir="$repo_root/docker-compose"
source_version=""
database_volume=""
backup_confirmed=false
old_workload_stopped=false

usage() {
  cat <<'EOF'
Usage:
  migrate-v3.sh --source-version 3.16.1 --backup-confirmed \
    --old-workload-stopped --volume NAME [--directory DIR]

The command starts the normal v4 application against the explicitly selected,
stopped database volume from v3.16.1 of the Noves Data App.
EOF
}

while (($#)); do
  case "$1" in
    --source-version) source_version="${2:?Missing source version}"; shift 2 ;;
    --backup-confirmed) backup_confirmed=true; shift ;;
    --old-workload-stopped) old_workload_stopped=true; shift ;;
    --volume) database_volume="${2:?Missing volume name}"; shift 2 ;;
    --directory) compose_dir="${2:?Missing directory}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "$source_version" == "3.16.1" ]] ||
  die "Migration requires a healthy source running v3.16.1 of the Noves Data App."
[[ "$backup_confirmed" == true ]] ||
  die "Migration requires --backup-confirmed."
[[ "$old_workload_stopped" == true ]] ||
  die "Migration requires --old-workload-stopped."
[[ -n "$database_volume" ]] || die "Migration requires --volume NAME."
[[ -f "$compose_dir/.env" ]] || die "Missing $compose_dir/.env."
[[ -f "$compose_dir/.state/capture.env" ]] ||
  die "Missing dedicated capture credentials at $compose_dir/.state/capture.env."

require_command docker
cd "$compose_dir"
DATABASE_VOLUME="$database_volume" \
exec docker compose --env-file .env \
  -f compose.yaml \
  -f compose.migrate-v3.yaml up -d

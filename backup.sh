#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
case "$profile" in dev|test|production) ;; *) echo "Usage: ./backup.sh <dev|test|production>" >&2; exit 2 ;; esac
env_file=".env.$profile"
[[ -f "$env_file" ]] || { echo "Missing $env_file" >&2; exit 1; }
env_get() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
BACKUP_DIR=$(env_get BACKUP_DIR)
BACKUP_RETENTION_DAYS=$(env_get BACKUP_RETENTION_DAYS)
BACKUP_DIR=${BACKUP_DIR:-./backups}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-14}
profile_dir="$BACKUP_DIR/$profile"
target="$profile_dir/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$target"

compose=(docker compose --project-name "monolith-$profile" --env-file "$env_file" --profile "$profile")
"${compose[@]}" exec -T db pg_dump -U monolith -d monolith_hub -Fc > "$target/database.dump"
"${compose[@]}" exec -T hub tar -C /data/storage -czf - . > "$target/hub-storage.tar.gz"
sha256sum "$target"/* > "$target/SHA256SUMS"
find "$profile_dir" -mindepth 1 -maxdepth 1 -type d -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} +
echo "Backup created: $target"

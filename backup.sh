#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
env_get() { sed -n "s/^$1=//p" .env | tail -n 1; }
BACKUP_DIR=$(env_get BACKUP_DIR)
BACKUP_RETENTION_DAYS=$(env_get BACKUP_RETENTION_DAYS)
BACKUP_DIR=${BACKUP_DIR:-./backups}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-14}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
target="$BACKUP_DIR/$stamp"
mkdir -p "$target"

for env in prod test; do
  docker compose exec -T "${env}-db" pg_dump -U monolith -d monolith_hub -Fc > "$target/${env}-database.dump"
  docker compose run --rm --no-deps -v "$PWD/$target:/backup" "${env}-hub" sh -c "tar -C /data/storage -czf /backup/${env}-storage.tar.gz ."
done
sha256sum "$target"/* > "$target/SHA256SUMS"
find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf -- {} +
echo "Backup created: $target"

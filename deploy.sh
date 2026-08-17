#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
[[ -f .env ]] || { echo "Missing .env; copy .env.example first." >&2; exit 1; }
env_get() { sed -n "s/^$1=//p" .env | tail -n 1; }
HUB_REPOSITORY=$(env_get HUB_REPOSITORY)
HUB_REF=$(env_get HUB_REF)
SITE_REPOSITORY=$(env_get SITE_REPOSITORY)
SITE_REF=$(env_get SITE_REF)
mkdir -p .runtime

sync_repo() {
  local url=$1 ref=$2 dir=$3
  if [[ ! -d "$dir/.git" ]]; then git clone "$url" "$dir"; fi
  git -C "$dir" fetch --tags --prune origin
  local resolved="$ref"
  git -C "$dir" rev-parse --verify --quiet "origin/$ref" >/dev/null && resolved="origin/$ref"
  git -C "$dir" checkout --detach "$resolved"
  git -C "$dir" reset --hard "$resolved"
}
sync_repo "$HUB_REPOSITORY" "$HUB_REF" .runtime/HubMonolith
sync_repo "$SITE_REPOSITORY" "$SITE_REF" .runtime/SiteMonolit
docker compose --env-file .env config --quiet
docker compose --env-file .env build --pull
docker compose --env-file .env up -d --remove-orphans
./health-check.sh

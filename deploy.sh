#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
case "$profile" in
  dev) ;;
  test|production)
    echo "Profile '$profile' is reserved and intentionally not deployable yet." >&2
    exit 2
    ;;
  *) echo "Usage: ./deploy.sh dev" >&2; exit 2 ;;
esac

env_file=".env.$profile"
[[ -f "$env_file" ]] || { echo "Missing $env_file; run sudo ./bootstrap.sh $profile first." >&2; exit 1; }
env_get() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
[[ $(env_get DEPLOY_PROFILE) == "$profile" ]] || { echo "Profile mismatch in $env_file" >&2; exit 1; }
[[ $(env_get DEPLOY_ENABLED) == "true" ]] || { echo "Profile '$profile' is disabled." >&2; exit 2; }

HUB_REPOSITORY=$(env_get HUB_REPOSITORY)
HUB_REF=$(env_get HUB_REF)
SITE_REPOSITORY=$(env_get SITE_REPOSITORY)
SITE_REF=$(env_get SITE_REF)
mkdir -p .runtime

sync_repo() {
  local url=$1 ref=$2 dir=$3 resolved=$2
  if [[ ! -d "$dir/.git" ]]; then git clone "$url" "$dir"; fi
  git -C "$dir" fetch --tags --prune origin
  git -C "$dir" rev-parse --verify --quiet "origin/$ref" >/dev/null && resolved="origin/$ref"
  git -C "$dir" checkout --detach "$resolved"
  git -C "$dir" reset --hard "$resolved"
}

sync_repo "$HUB_REPOSITORY" "$HUB_REF" .runtime/HubMonolith
sync_repo "$SITE_REPOSITORY" "$SITE_REF" .runtime/SiteMonolit

compose=(docker compose --project-name "monolith-$profile" --env-file "$env_file" --profile "$profile")
"${compose[@]}" config --quiet
"${compose[@]}" build --pull
"${compose[@]}" up -d --remove-orphans
./health-check.sh "$profile"

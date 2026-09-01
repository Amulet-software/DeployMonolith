#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
case "$profile" in dev|test|production) ;; *) echo "Usage: ./health-check.sh <dev|test|production>" >&2; exit 2 ;; esac
env_file=".env.$profile"
[[ -f "$env_file" ]] || { echo "Missing $env_file" >&2; exit 1; }
env_get() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
SITE_PUBLIC_URL=$(env_get SITE_PUBLIC_URL)
HUB_PUBLIC_BASE_URL=$(env_get HUB_PUBLIC_BASE_URL)
SITE_PUBLIC_URL=${SITE_PUBLIC_URL%/}
HUB_PUBLIC_BASE_URL=${HUB_PUBLIC_BASE_URL%/}

for attempt in {1..30}; do
  if curl --fail --silent --show-error --max-time 5 "$SITE_PUBLIC_URL/" >/dev/null \
    && curl --fail --silent --show-error --max-time 5 "$HUB_PUBLIC_BASE_URL/health/ready" >/dev/null \
    && curl --fail --silent --show-error --max-time 5 "$SITE_PUBLIC_URL/monolith/releases.json" >/dev/null \
    && curl --fail --silent --show-error --max-time 5 "$SITE_PUBLIC_URL/monolith/modules/catalog.json" >/dev/null; then
    echo "Monolith $profile is healthy: $SITE_PUBLIC_URL, $HUB_PUBLIC_BASE_URL"
    echo "Legacy gateway is healthy: /monolith/releases.json, /monolith/modules/catalog.json"
    exit 0
  fi
  sleep 5
done

echo "Monolith $profile health-check failed, including legacy Site -> Hub gateway." >&2
docker compose --project-name "monolith-$profile" --env-file "$env_file" --profile "$profile" ps
exit 1

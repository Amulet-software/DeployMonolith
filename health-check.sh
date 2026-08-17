#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"
env_get() { sed -n "s/^$1=//p" .env | tail -n 1; }
PROD_SITE_HOST=$(env_get PROD_SITE_HOST)
PROD_HUB_HOST=$(env_get PROD_HUB_HOST)
TEST_SITE_HOST=$(env_get TEST_SITE_HOST)
TEST_HUB_HOST=$(env_get TEST_HUB_HOST)
for attempt in {1..30}; do
  failed=0
  for url in "http://${PROD_SITE_HOST}/" "http://${PROD_HUB_HOST}/health/ready" "http://${TEST_SITE_HOST}/" "http://${TEST_HUB_HOST}/health/ready"; do
    curl --fail --silent --show-error --max-time 5 --resolve "$(echo "$url" | sed -E 's#http://([^/]+).*#\1#'):80:127.0.0.1" "$url" >/dev/null || failed=1
  done
  [[ $failed -eq 0 ]] && { echo "All Monolith endpoints are healthy."; exit 0; }
  sleep 5
done
docker compose ps
exit 1

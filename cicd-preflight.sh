#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-dev}
expected_user=${MONOLITH_DEPLOY_USER:-monolith}
expected_ip=${MONOLITH_DEV_IP:-192.168.1.32}

[[ "$profile" == "dev" ]] || { echo "Only dev is allowed for CI/CD preflight." >&2; exit 2; }
[[ $(id -un) == "$expected_user" ]] || {
  echo "CI/CD runner must run as '$expected_user'; current user: $(id -un)" >&2
  exit 1
}
command -v ip >/dev/null || { echo "Missing ip command (iproute2)." >&2; exit 1; }
ip -4 -o addr show | grep -Eq "[[:space:]]${expected_ip//./\.}/" || {
  echo "This runner is not on DEV host $expected_ip." >&2
  exit 1
}
command -v docker >/dev/null || { echo "Docker is not installed." >&2; exit 1; }
docker info >/dev/null || {
  echo "Docker is not accessible to user '$expected_user'. Check docker group membership and restart the runner service/session." >&2
  exit 1
}
command -v rsync >/dev/null || { echo "rsync is not installed." >&2; exit 1; }
[[ -r .env.dev ]] || { echo "Missing or unreadable .env.dev in $(pwd)." >&2; exit 1; }
[[ -x ./deploy.sh ]] || { echo "deploy.sh is not executable." >&2; exit 1; }
[[ -w . ]] || { echo "$(pwd) is not writable by '$expected_user'." >&2; exit 1; }

echo "DEV CI/CD preflight passed: user=$expected_user host=$expected_ip docker=ready"

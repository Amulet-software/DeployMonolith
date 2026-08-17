#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
if [[ "$profile" != "dev" ]]; then
  echo "Usage: sudo ./bootstrap.sh dev" >&2
  echo "Profiles test and production are reserved and intentionally disabled." >&2
  exit 2
fi
if [[ ${EUID} -ne 0 ]]; then echo "Run as root: sudo ./bootstrap.sh dev" >&2; exit 1; fi
command -v apt-get >/dev/null || { echo "Supported bootstrap OS: Debian/Ubuntu" >&2; exit 1; }

apt-get update
apt-get install -y ca-certificates curl git openssl openssh-client
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

env_file=".env.$profile"
[[ -f "$env_file" ]] || cp "profiles/$profile.env.example" "$env_file"
for key in POSTGRES_PASSWORD HUB_ADMIN_KEY; do
  value=$(openssl rand -hex 32)
  sed -i "s/^${key}=change-me$/${key}=${value}/" "$env_file"
done
chmod 600 "$env_file"

echo "Infrastructure prerequisites are installed. Running DEV deploy preflight and deployment."
echo "Private GitHub repositories must already be readable via SSH credentials or GITHUB_TOKEN_FILE in $env_file."
./deploy.sh "$profile"
echo "DEV bootstrap complete: site http://192.168.1.32, hub http://192.168.1.32:8080"

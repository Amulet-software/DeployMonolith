#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then echo "Run as root: sudo ./bootstrap.sh" >&2; exit 1; fi
command -v apt-get >/dev/null || { echo "Supported bootstrap OS: Debian/Ubuntu" >&2; exit 1; }

apt-get update
apt-get install -y ca-certificates curl git openssl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

[[ -f .env ]] || cp .env.example .env
for key in PROD_POSTGRES_PASSWORD PROD_HUB_ADMIN_KEY TEST_POSTGRES_PASSWORD TEST_HUB_ADMIN_KEY; do
  value=$(openssl rand -hex 32)
  sed -i "s/^${key}=change-me$/${key}=${value}/" .env
done
chmod 600 .env
./deploy.sh
echo "Bootstrap complete. Configure DNS and HTTPS as described in README.md."


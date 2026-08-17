#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
mode=${2:-}
deploy_user=${MONOLITH_DEPLOY_USER:-monolith}

if [[ "$profile" != "dev" ]]; then
  echo "Usage: sudo ./bootstrap.sh dev [--prepare-only]" >&2
  echo "Profiles test and production are reserved and intentionally disabled." >&2
  exit 2
fi
case "$mode" in
  ""|--prepare-only) ;;
  *) echo "Usage: sudo ./bootstrap.sh dev [--prepare-only]" >&2; exit 2 ;;
esac
if [[ ${EUID} -ne 0 ]]; then echo "Run as root: sudo ./bootstrap.sh dev [--prepare-only]" >&2; exit 1; fi
command -v apt-get >/dev/null || { echo "Supported bootstrap OS: Debian/Ubuntu" >&2; exit 1; }

disable_cdrom_sources() {
  local source_file
  local -a source_files=(/etc/apt/sources.list)
  shopt -s nullglob
  source_files+=(/etc/apt/sources.list.d/*.list)
  shopt -u nullglob

  for source_file in "${source_files[@]}"; do
    [[ -f "$source_file" ]] || continue
    if grep -Eq '^[[:space:]]*deb[[:space:]].*(cdrom:|file:/+cdrom)' "$source_file"; then
      [[ -f "$source_file.monolith-backup" ]] || cp -a "$source_file" "$source_file.monolith-backup"
      sed -i -E '/^[[:space:]]*deb[[:space:]].*(cdrom:|file:\/+cdrom)/s/^/# disabled by MonolithDeploy: /' "$source_file"
      echo "Disabled stale CD-ROM APT source in $source_file"
    fi
  done
}

disable_cdrom_sources
apt-get update
apt-get install -y ca-certificates curl git openssl openssh-client rsync iproute2
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

if ! id "$deploy_user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$deploy_user"
fi
usermod -aG docker "$deploy_user"

env_file=".env.$profile"
[[ -f "$env_file" ]] || cp "profiles/$profile.env.example" "$env_file"
for key in POSTGRES_PASSWORD HUB_ADMIN_KEY; do
  value=$(openssl rand -hex 32)
  sed -i "s/^${key}=change-me$/${key}=${value}/" "$env_file"
done

repo_root=$(pwd)
install -d -o "$deploy_user" -g "$deploy_user" .runtime backups
chown -R "$deploy_user":"$deploy_user" "$repo_root"
chmod 600 "$env_file"

echo "DEV host prerequisites are installed."
echo "Deploy user: $deploy_user"
echo "Docker: $(docker --version)"
echo "Compose: $(docker compose version)"

if [[ "$mode" == "--prepare-only" ]]; then
  echo "Prepare-only mode complete. No Site/Hub containers were deployed."
  echo "Next: configure private GitHub read access for $deploy_user, register the MonolithDeploy self-hosted runner with label monolith-dev, then run the Deploy DEV workflow."
  exit 0
fi

echo "Running DEV deploy as $deploy_user."
echo "Private HubMonolith/SiteMonolit repositories must already be readable via SSH credentials or GITHUB_TOKEN_FILE in $env_file."
runuser -u "$deploy_user" -- ./deploy.sh "$profile"
echo "DEV bootstrap complete: site http://192.168.1.32, hub http://192.168.1.32:8080"

#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
mode=${2:-}
deploy_user=${MONOLITH_DEPLOY_USER:-monolith}

if [[ "$profile" != "dev" ]]; then
  echo "Usage: sudo bash ./bootstrap.sh dev [--prepare-only]" >&2
  echo "Profiles test and production are reserved and intentionally disabled." >&2
  exit 2
fi
case "$mode" in
  ""|--prepare-only) ;;
  *) echo "Usage: sudo bash ./bootstrap.sh dev [--prepare-only]" >&2; exit 2 ;;
esac
if [[ ${EUID} -ne 0 ]]; then echo "Run as root: sudo bash ./bootstrap.sh dev [--prepare-only]" >&2; exit 1; fi
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
      sed -i -E '/^[[:space:]]*deb[[:space:]].*(cdrom:|file:\/+cdrom)/s/^/# disabled by DeployMonolith: /' "$source_file"
      echo "Disabled stale CD-ROM APT source in $source_file"
    fi
  done
}

disable_cdrom_sources
apt-get update
apt-get install -y ca-certificates curl git jq openssl openssh-client rsync iproute2
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
env_created=false
if [[ ! -f "$env_file" ]]; then
  cp "profiles/$profile.env.example" "$env_file"
  env_created=true
fi

env_get() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
set_env() {
  local key=$1 value=$2 escaped
  escaped=${value//|/\\|}
  if grep -q "^${key}=" "$env_file"; then
    sed -i "s|^${key}=.*|${key}=${escaped}|" "$env_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$env_file"
  fi
}

detect_dev_ip() {
  local detected
  detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' || true)
  if [[ -z "$detected" ]]; then
    detected=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  fi
  printf '%s' "${detected:-127.0.0.1}"
}

# New clean hosts are self-configuring. Existing explicitly configured URLs are
# preserved; only template/legacy defaults are migrated automatically.
dev_ip=$(detect_dev_ip)
site_public=$(env_get SITE_PUBLIC_URL || true)
hub_public=$(env_get HUB_PUBLIC_BASE_URL || true)
cors_origins=$(env_get HUB_CORS_ORIGINS || true)
if [[ "$env_created" == "true" || "$site_public" == "http://127.0.0.1" || "$site_public" == "http://192.168.1.32" ]]; then
  set_env SITE_PUBLIC_URL "http://${dev_ip}"
fi
if [[ "$env_created" == "true" || "$hub_public" == "http://127.0.0.1:8080" || "$hub_public" == "http://192.168.1.32:8080" ]]; then
  set_env HUB_PUBLIC_BASE_URL "http://${dev_ip}:8080"
fi
if [[ "$env_created" == "true" || "$cors_origins" == '["http://127.0.0.1"]' || "$cors_origins" == '["http://192.168.1.32"]' ]]; then
  set_env HUB_CORS_ORIGINS "[\"http://${dev_ip}\"]"
fi
set_env HUB_ENVIRONMENT shared

for key in POSTGRES_PASSWORD HUB_ADMIN_KEY; do
  if grep -q "^${key}=change-me$" "$env_file"; then
    value=$(openssl rand -hex 32)
    set_env "$key" "$value"
  fi
done

repo_root=$(pwd)
install -d -o "$deploy_user" -g "$deploy_user" .runtime backups
chown -R "$deploy_user":"$deploy_user" "$repo_root"
chmod 600 "$env_file"
chmod 0755 bootstrap.sh deploy.sh health-check.sh backup.sh cicd-preflight.sh 2>/dev/null || true
chmod 0755 deploy-key-setup.sh install-runner.sh deployment-status.sh 2>/dev/null || true

echo "DEV host prerequisites are installed."
echo "Deploy user: $deploy_user"
echo "Detected DEV address: $dev_ip"
echo "Site URL: $(env_get SITE_PUBLIC_URL)"
echo "Shared Hub URL: $(env_get HUB_PUBLIC_BASE_URL)"
echo "Docker: $(docker --version)"
echo "Compose: $(docker compose version)"

if [[ "$mode" == "--prepare-only" ]]; then
  echo "Prepare-only mode complete. No Site/Hub containers were deployed."
  echo "Next steps:"
  echo "  1. sudo bash ./deploy-key-setup.sh dev generate"
  echo "  2. Register the three printed public keys in GitHub as read-only deploy keys."
  echo "  3. sudo bash ./deploy-key-setup.sh dev verify"
  echo "  4. Pipe a one-time GitHub runner registration token to sudo bash ./install-runner.sh dev --token-stdin"
  echo "  5. Run the Deploy DEV workflow."
  exit 0
fi

echo "Running DEV deploy as $deploy_user."
echo "Private HubMonolith/SiteMonolit repositories must already be readable through the configured SSH deploy keys."
runuser -u "$deploy_user" -- ./deploy.sh "$profile"
echo "DEV bootstrap complete: site $(env_get SITE_PUBLIC_URL), shared hub $(env_get HUB_PUBLIC_BASE_URL)"

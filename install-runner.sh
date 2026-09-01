#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
mode=${2:---token-stdin}
deploy_user=${MONOLITH_DEPLOY_USER:-monolith}
repo_url=${MONOLITH_RUNNER_REPOSITORY_URL:-https://github.com/Amulet-software/DeployMonolith}
runner_label=${MONOLITH_RUNNER_LABEL:-monolith-dev}
runner_name=${MONOLITH_RUNNER_NAME:-monolith-dev-$(hostname)}
runner_root=${MONOLITH_RUNNER_ROOT:-/home/$deploy_user/actions-runner}

stage() {
  printf 'MONOLITH_STAGE=%s\n' "$1"
}

[[ "$profile" == "dev" ]] || {
  echo "Usage: sudo bash ./install-runner.sh dev --token-stdin" >&2
  echo "Profiles test and production are intentionally disabled." >&2
  exit 2
}
[[ "$mode" == "--token-stdin" ]] || { echo "Registration token must be supplied through stdin." >&2; exit 2; }
[[ ${EUID} -eq 0 ]] || { echo "Run as root with sudo." >&2; exit 1; }
id "$deploy_user" >/dev/null 2>&1 || { echo "Deploy user '$deploy_user' does not exist." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required. Re-run bootstrap.sh dev --prepare-only." >&2; exit 1; }

IFS= read -r registration_token
registration_token=${registration_token//$'\r'/}
registration_token=${registration_token//$'\n'/}
[[ -n "$registration_token" ]] || { echo "Runner registration token is empty." >&2; exit 1; }

case "$(uname -m)" in
  x86_64|amd64) runner_arch=x64 ;;
  aarch64|arm64) runner_arch=arm64 ;;
  *) echo "Unsupported runner architecture: $(uname -m)" >&2; exit 1 ;;
esac

stage resolve-release
release_json=$(curl -fsSL --connect-timeout 15 --max-time 90 --retry 3 --retry-delay 2 https://api.github.com/repos/actions/runner/releases/latest)
runner_version=$(jq -r '.tag_name // empty' <<<"$release_json" | sed 's/^v//')
[[ -n "$runner_version" ]] || { echo "Could not resolve latest actions/runner version." >&2; exit 1; }
archive_name="actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"
asset_url=$(jq -r --arg name "$archive_name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release_json")
asset_digest=$(jq -r --arg name "$archive_name" '.assets[] | select(.name == $name) | (.digest // "")' <<<"$release_json")
[[ -n "$asset_url" && "$asset_url" != "null" ]] || { echo "Runner archive not found: $archive_name" >&2; exit 1; }

install -d -m 0755 -o "$deploy_user" -g "$deploy_user" "$runner_root"
if [[ ! -f "$runner_root/run.sh" ]]; then
  tmp_archive=$(mktemp)
  trap 'rm -f "$tmp_archive"; unset registration_token' EXIT
  stage download-runner
  echo "Downloading GitHub Actions runner $runner_version ($runner_arch)"
  curl -fL --connect-timeout 15 --max-time 600 --retry 3 --retry-delay 2 "$asset_url" -o "$tmp_archive"
  if [[ "$asset_digest" == sha256:* ]]; then
    stage verify-runner
    expected=${asset_digest#sha256:}
    echo "$expected  $tmp_archive" | sha256sum -c -
  fi
  stage extract-runner
  tar -xzf "$tmp_archive" -C "$runner_root"
  chown -R "$deploy_user:$deploy_user" "$runner_root"
  if [[ -x "$runner_root/bin/installdependencies.sh" ]]; then
    stage install-dependencies
    "$runner_root/bin/installdependencies.sh"
  fi
else
  stage reuse-runner
  echo "Runner files already exist in $runner_root; keeping installed version."
fi

if [[ -f "$runner_root/.runner" ]]; then
  stage reuse-registration
  echo "Runner is already configured. Ensuring service is installed and started."
else
  stage register-runner
  runuser -u "$deploy_user" -- bash -c '
    cd "$1"
    ./config.sh --unattended --replace \
      --url "$2" \
      --token "$3" \
      --name "$4" \
      --labels "$5" \
      --work _work
  ' _ "$runner_root" "$repo_url" "$registration_token" "$runner_name" "$runner_label"
fi

unset registration_token
cd "$runner_root"
stage install-service
if ! ./svc.sh status >/dev/null 2>&1; then
  ./svc.sh install "$deploy_user" || true
fi
stage start-service
./svc.sh start
sleep 2
stage verify-service
./svc.sh status

stage ready
echo "GitHub Actions runner ready:"
echo "  repository=$repo_url"
echo "  name=$runner_name"
echo "  label=$runner_label"
echo "  user=$deploy_user"

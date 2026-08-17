#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")"

profile=${1:-}
mode=${2:-}
case "$profile" in
  dev) ;;
  test|production)
    echo "Profile '$profile' is reserved and intentionally not deployable yet." >&2
    exit 2
    ;;
  *) echo "Usage: ./deploy.sh dev [--preflight-only]" >&2; exit 2 ;;
esac
case "$mode" in
  ""|--preflight-only) ;;
  *) echo "Usage: ./deploy.sh dev [--preflight-only]" >&2; exit 2 ;;
esac

env_file=".env.$profile"
[[ -f "$env_file" ]] || { echo "Missing $env_file; run sudo ./bootstrap.sh $profile --prepare-only first." >&2; exit 1; }
env_get() { sed -n "s/^$1=//p" "$env_file" | tail -n 1; }
[[ $(env_get DEPLOY_PROFILE) == "$profile" ]] || { echo "Profile mismatch in $env_file" >&2; exit 1; }
[[ $(env_get DEPLOY_ENABLED) == "true" ]] || { echo "Profile '$profile' is disabled." >&2; exit 2; }

HUB_REPOSITORY=$(env_get HUB_REPOSITORY)
HUB_REF=$(env_get HUB_REF)
SITE_REPOSITORY=$(env_get SITE_REPOSITORY)
SITE_REF=$(env_get SITE_REF)
GITHUB_TOKEN_FILE=$(env_get GITHUB_TOKEN_FILE || true)
mkdir -p .runtime

askpass_file=""
cleanup() {
  [[ -z "$askpass_file" ]] || rm -f "$askpass_file"
  unset MONOLITH_GITHUB_TOKEN GIT_ASKPASS || true
}
trap cleanup EXIT

setup_git_auth() {
  export GIT_TERMINAL_PROMPT=0
  [[ -n "$GITHUB_TOKEN_FILE" ]] || return 0
  [[ -f "$GITHUB_TOKEN_FILE" ]] || {
    echo "GitHub token file not found: $GITHUB_TOKEN_FILE" >&2
    exit 1
  }
  [[ -r "$GITHUB_TOKEN_FILE" ]] || {
    echo "GitHub token file is not readable by user $(id -un): $GITHUB_TOKEN_FILE" >&2
    exit 1
  }
  local file_mode
  file_mode=$(stat -c '%a' "$GITHUB_TOKEN_FILE")
  if [[ "$file_mode" != "600" && "$file_mode" != "400" ]]; then
    echo "GitHub token file must have mode 600 or 400: $GITHUB_TOKEN_FILE (current: $file_mode)" >&2
    exit 1
  fi
  MONOLITH_GITHUB_TOKEN=$(tr -d '\r\n' < "$GITHUB_TOKEN_FILE")
  [[ -n "$MONOLITH_GITHUB_TOKEN" ]] || { echo "GitHub token file is empty." >&2; exit 1; }
  export MONOLITH_GITHUB_TOKEN
  askpass_file=$(mktemp)
  cat > "$askpass_file" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' 'x-access-token' ;;
  *Password*) printf '%s\n' "$MONOLITH_GITHUB_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
  chmod 700 "$askpass_file"
  export GIT_ASKPASS="$askpass_file"
}

preflight_repo() {
  local label=$1 url=$2
  echo "Checking GitHub access: $label"
  if ! git ls-remote "$url" HEAD >/dev/null 2>&1; then
    echo "Cannot read $label repository: $url" >&2
    echo "Configure SSH credentials or set GITHUB_TOKEN_FILE to a token file readable only by the deploy user." >&2
    exit 1
  fi
}

sync_repo() {
  local url=$1 ref=$2 dir=$3 resolved=$2
  if [[ ! -d "$dir/.git" ]]; then
    git clone --no-checkout "$url" "$dir"
  else
    git -C "$dir" remote set-url origin "$url"
  fi
  git -C "$dir" fetch --tags --prune origin
  if git -C "$dir" rev-parse --verify --quiet "origin/$ref^{commit}" >/dev/null; then
    resolved="origin/$ref"
  elif ! git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "Ref '$ref' does not exist in $url" >&2
    exit 1
  fi
  git -C "$dir" checkout --detach "$resolved"
  git -C "$dir" reset --hard "$resolved"
}

setup_git_auth
preflight_repo "HubMonolith" "$HUB_REPOSITORY"
preflight_repo "SiteMonolit" "$SITE_REPOSITORY"

if [[ "$mode" == "--preflight-only" ]]; then
  echo "Git access preflight passed for HubMonolith and SiteMonolit. No containers were built or started."
  exit 0
fi

sync_repo "$HUB_REPOSITORY" "$HUB_REF" .runtime/HubMonolith
sync_repo "$SITE_REPOSITORY" "$SITE_REF" .runtime/SiteMonolit

compose=(docker compose --project-name "monolith-$profile" --env-file "$env_file" --profile "$profile")
"${compose[@]}" config --quiet
"${compose[@]}" build --pull
"${compose[@]}" up -d --remove-orphans
./health-check.sh "$profile"

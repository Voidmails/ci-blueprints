#!/usr/bin/env bash
# Deploy one service of one environment and roll back automatically if it does not become healthy.
#
#   deploy.sh <service> <image-tag> <environment>
#
# Lives in /opt/voidmails next to docker-compose.yml and <environment>.env. CI runs it through the
# SSH forced command of the deploy key (args arrive in SSH_ORIGINAL_COMMAND). Humans run it directly,
# e.g. to roll back: ./deploy.sh backend <older-sha> production
set -euo pipefail

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
PROJECT_PREFIX="${PROJECT_PREFIX:-voidmails}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  read -r -a args <<<"$SSH_ORIGINAL_COMMAND"
  # CI sends "<path>/deploy.sh <service> <tag> <env>" so it also works without a forced command.
  if [[ "${args[0]:-}" == */deploy.sh || "${args[0]:-}" == deploy.sh ]]; then
    args=("${args[@]:1}")
  fi
else
  args=("$@")
fi

[[ ${#args[@]} -eq 3 ]] || die "usage: deploy.sh <service> <image-tag> <environment>"
service="${args[0]}"
tag="${args[1]}"
env_name="${args[2]}"

[[ "$service" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "invalid service '$service'"
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid image tag '$tag'"
[[ "$env_name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid environment '$env_name'"

cd "$BASE_DIR"
env_file="$BASE_DIR/$env_name.env"
[[ -f "$env_file" ]] || die "unknown environment '$env_name' ($env_file not found)"

tag_var="$(tr 'a-z-' 'A-Z_' <<<"$service")_TAG"
compose=(docker compose --project-name "$PROJECT_PREFIX-$env_name" --env-file "$env_file")

# Deploys of different services share the env file, so serialize them per environment.
exec 9>"$BASE_DIR/.deploy-$env_name.lock"
flock -w 600 9 || die "timed out waiting for another deploy to $env_name"

if ! "${compose[@]}" config --services | grep -qxF "$service"; then
  die "service '$service' is not defined or not enabled (COMPOSE_PROFILES) in $env_name"
fi

get_tag() { sed -n "s/^${tag_var}=//p" "$env_file" | tail -n 1; }

# Rewrites <SERVICE>_TAG in the env file atomically. An empty value removes the line.
set_tag() {
  local tmp
  tmp="$(mktemp "$env_file.XXXXXX")"
  awk -v key="$tag_var" -v val="$1" '
    index($0, key "=") == 1 { if (!done && val != "") print key "=" val; done = 1; next }
    { print }
    END { if (!done && val != "") print key "=" val }
  ' "$env_file" >"$tmp"
  chmod --reference="$env_file" "$tmp"
  mv "$tmp" "$env_file"
}

record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$env_name" "$service" "$1" "$2" \
    >>"$BASE_DIR/deploy-history.log"
}

start_service() {
  "${compose[@]}" up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" "$service"
}

prev="$(get_tag)"
log "deploying $service:$tag to $env_name (previous: ${prev:-none})"

set_tag "$tag"
if ! "${compose[@]}" pull --quiet "$service"; then
  set_tag "$prev"
  record "$tag" pull-failed
  die "could not pull $service:$tag; nothing was changed"
fi

if start_service; then
  record "$tag" ok
  docker image prune -f >/dev/null 2>&1 || true
  log "$service:$tag is healthy in $env_name"
  exit 0
fi

log "$service:$tag did not become healthy within ${HEALTH_TIMEOUT}s; last logs:"
"${compose[@]}" logs --no-color --tail 50 "$service" >&2 || true

if [[ -z "$prev" || "$prev" == "$tag" ]]; then
  record "$tag" failed-no-rollback
  die "no previous tag to roll back to; $service is left as is"
fi

log "rolling back $service to $prev"
set_tag "$prev"
if start_service; then
  record "$tag" rolled-back-to:"$prev"
  die "deploy of $service:$tag failed; rolled back to $prev"
fi
record "$tag" rollback-failed
die "deploy of $service:$tag failed AND rollback to $prev is unhealthy; manual action needed"

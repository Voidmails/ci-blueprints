#!/usr/bin/env bash
# Deploy one service of one environment and roll back automatically if it does not become healthy.
#
#   deploy.sh <service> <image-tag> <environment> [--config=env|--config=json]
#
# With --config, stdin carries a gzipped tar of the service repo's deploy/<environment>/ folder:
# values.yaml (plain) and/or secrets.yaml (SOPS-encrypted, decrypted here with this server's age key).
#   --config=env   values + secrets -> env/<environment>/<service>.env      (mode 600)
#   --config=json  values only      -> config/<environment>/<service>.json  (mode 644, public)
# Image tag and config are rolled back together.
#
# Lives in /opt/voidmails next to docker-compose.yml and <environment>.env. CI runs it through the
# SSH forced command of the deploy key (args arrive in SSH_ORIGINAL_COMMAND). Humans run it directly,
# e.g. to roll back: ./deploy.sh backend <older-sha> production
set -euo pipefail
umask 077

HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
PROJECT_PREFIX="${PROJECT_PREFIX:-voidmails}"
MAX_BUNDLE_BYTES=1048576
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[deploy] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  read -r -a args <<<"$SSH_ORIGINAL_COMMAND"
  # CI sends "<path>/deploy.sh <service> <tag> <env> [...]" so it also works without a forced command.
  if [[ "${args[0]:-}" == */deploy.sh || "${args[0]:-}" == deploy.sh ]]; then
    args=("${args[@]:1}")
  fi
else
  args=("$@")
fi

[[ ${#args[@]} -eq 3 || ${#args[@]} -eq 4 ]] ||
  die "usage: deploy.sh <service> <image-tag> <environment> [--config=env|--config=json]"
service="${args[0]}"
tag="${args[1]}"
env_name="${args[2]}"
config_format=""
if [[ ${#args[@]} -eq 4 ]]; then
  [[ "${args[3]}" =~ ^--config=(env|json)$ ]] || die "invalid option '${args[3]}'"
  config_format="${BASH_REMATCH[1]}"
fi

[[ "$service" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "invalid service '$service'"
[[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "invalid image tag '$tag'"
[[ "$env_name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "invalid environment '$env_name'"

cd "$BASE_DIR"
env_file="$BASE_DIR/$env_name.env"
[[ -f "$env_file" ]] || die "unknown environment '$env_name' ($env_file not found)"

tag_var="$(tr 'a-z-' 'A-Z_' <<<"$service")_TAG"
compose=(docker compose --project-name "$PROJECT_PREFIX-$env_name" --env-file "$env_file")
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Deploys of different services share the env file, so serialize them per environment.
exec 9>"$BASE_DIR/.deploy-$env_name.lock"
flock -w 600 9 || die "timed out waiting for another deploy to $env_name"

if ! "${compose[@]}" config --services | grep -qxF "$service"; then
  die "service '$service' is not defined or not enabled (COMPOSE_PROFILES) in $env_name"
fi

# Validates the bundle and renders values.yaml (+ decrypted secrets) into the target file format.
CONFIG_PY="$(
  cat <<'PY'
import json, re, sys, tarfile

KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
ALLOWED = ("values.yaml", "secrets.yaml")

def fail(msg):
    sys.stderr.write(f"[deploy] ERROR: {msg}\n")
    sys.exit(1)

def extract(bundle, outdir):
    try:
        archive = tarfile.open(bundle, "r:gz")
        members = archive.getmembers()
    except (tarfile.TarError, OSError, EOFError) as e:
        fail(f"config bundle is not a gzipped tar: {e}")
    found = set()
    for m in members:
        name = m.name[2:] if m.name.startswith("./") else m.name
        if m.isdir() and name in ("", "."):
            continue
        if name not in ALLOWED or not m.isfile() or name in found:
            fail(f"unexpected entry {m.name!r} in config bundle (only values.yaml and secrets.yaml)")
        found.add(name)
        with open(f"{outdir}/{name}", "wb") as out:
            out.write(archive.extractfile(m).read())
    if not found:
        fail("config bundle contains neither values.yaml nor secrets.yaml")

def load_values(path):
    import yaml
    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        return {}
    except yaml.YAMLError as e:
        fail(f"values.yaml is not valid YAML: {e}")
    if data is None:
        return {}
    if not isinstance(data, dict):
        fail("values.yaml must be a mapping of KEY: value")
    return data

def render(fmt, workdir):
    values = load_values(f"{workdir}/values.yaml")
    if fmt == "json":
        print(json.dumps(values, indent=2, ensure_ascii=False, default=str))
        return
    try:
        with open(f"{workdir}/secrets.json", encoding="utf-8") as f:
            secrets = json.load(f)
    except FileNotFoundError:
        secrets = {}
    seen, lines = set(), []
    for source, data in (("values.yaml", values), ("secrets.yaml", secrets)):
        if not isinstance(data, dict):
            fail(f"{source} must be a mapping of KEY: value")
        for key, value in data.items():
            if not isinstance(key, str) or not KEY.match(key):
                fail(f"{source}: invalid variable name {key!r}")
            if key in seen:
                fail(f"{key} is defined in both values.yaml and secrets.yaml")
            seen.add(key)
            if isinstance(value, (dict, list)):
                fail(f"{source}: {key} must be a single value, not a list or map")
            if isinstance(value, bool):
                value = "true" if value else "false"
            value = "" if value is None else str(value)
            if "\n" in value or "\r" in value:
                fail(f"{source}: {key} contains a line break, which an env file cannot hold")
            lines.append(f"{key}={value}")
    print("\n".join(lines))

if sys.argv[1] == "extract":
    extract(sys.argv[2], sys.argv[3])
else:
    render(sys.argv[2], sys.argv[3])
PY
)"

config_target=""
config_changed=0
had_config=0

if [[ -n "$config_format" ]]; then
  head -c $((MAX_BUNDLE_BYTES + 1)) >"$tmp/bundle.tgz"
  (($(stat -c %s "$tmp/bundle.tgz") <= MAX_BUNDLE_BYTES)) || die "config bundle is larger than $MAX_BUNDLE_BYTES bytes"
  python3 -c "$CONFIG_PY" extract "$tmp/bundle.tgz" "$tmp"
  if [[ -f "$tmp/secrets.yaml" ]]; then
    [[ "$config_format" == env ]] || die "secrets.yaml is not allowed with --config=json: that config is public"
    sops decrypt --input-type yaml --output-type json "$tmp/secrets.yaml" >"$tmp/secrets.json" ||
      die "could not decrypt secrets.yaml: is it encrypted with sops for this server's age key?"
  fi
  python3 -c "$CONFIG_PY" render "$config_format" "$tmp" >"$tmp/rendered"
  rm -f "$tmp/secrets.json"

  if [[ "$config_format" == env ]]; then
    config_dir="$BASE_DIR/env/$env_name" config_target="$config_dir/$service.env" config_mode=600
  else
    config_dir="$BASE_DIR/config/$env_name" config_target="$config_dir/$service.json" config_mode=644
  fi
  [[ "$config_format" == env ]] || umask 022
  mkdir -p "$config_dir"
  umask 077
  if [[ -f "$config_target" ]]; then
    cp "$config_target" "$tmp/previous-config"
    had_config=1
    cmp -s "$tmp/rendered" "$config_target" || config_changed=1
  else
    config_changed=1
  fi
fi

get_tag() { sed -n "s/^${tag_var}=//p" "$env_file" | tail -n 1; }

# Rewrites <SERVICE>_TAG in the env file atomically. An empty value removes the line.
set_tag() {
  local tmp_file
  tmp_file="$(mktemp "$env_file.XXXXXX")"
  awk -v key="$tag_var" -v val="$1" '
    index($0, key "=") == 1 { if (!done && val != "") print key "=" val; done = 1; next }
    { print }
    END { if (!done && val != "") print key "=" val }
  ' "$env_file" >"$tmp_file"
  chmod --reference="$env_file" "$tmp_file"
  mv "$tmp_file" "$env_file"
}

# Written in place (same inode), so a running container that bind-mounts the file sees the change.
write_config() {
  [[ -f "$config_target" ]] || install -m "$config_mode" /dev/null "$config_target"
  cat "$1" >"$config_target"
  chmod "$config_mode" "$config_target"
}

restore_config() {
  [[ -n "$config_target" ]] || return 0
  if ((had_config)); then
    write_config "$tmp/previous-config"
  else
    rm -f "$config_target"
  fi
}

record() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$env_name" "$service" "$1" "$2" \
    >>"$BASE_DIR/deploy-history.log"
}

start_service() {
  "${compose[@]}" up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" "$service"
}

prev="$(get_tag)"
log "deploying $service:$tag to $env_name (previous: ${prev:-none}${config_target:+, config ${config_target#"$BASE_DIR"/}})"

set_tag "$tag"
[[ -z "$config_target" ]] || write_config "$tmp/rendered"
if ! "${compose[@]}" pull --quiet "$service"; then
  set_tag "$prev"
  restore_config
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

if [[ -z "$prev" ]] || [[ "$prev" == "$tag" && $config_changed -eq 0 ]]; then
  record "$tag" failed-no-rollback
  die "no previous version to roll back to; $service is left as is"
fi

log "rolling back $service to $prev${config_target:+ and its previous config}"
set_tag "$prev"
restore_config
if start_service; then
  record "$tag" rolled-back-to:"$prev"
  die "deploy of $service:$tag failed; rolled back to $prev"
fi
record "$tag" rollback-failed
die "deploy of $service:$tag failed AND rollback to $prev is unhealthy; manual action needed"

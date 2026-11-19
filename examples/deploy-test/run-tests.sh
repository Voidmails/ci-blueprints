#!/usr/bin/env bash
# End-to-end test of servers/deploy.sh against a local registry: deploy, upgrade, failed deploy with
# automatic rollback, forced-command argument parsing, input validation, and SOPS-encrypted config
# (rendering, rollback of config together with the image, rejection of bad bundles).
#   examples/deploy-test/run-tests.sh   (needs docker, sops, age, python3-yaml; uses localhost:5000)
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
image=localhost:5000/deploy-sample
export HEALTH_TIMEOUT=30 PROJECT_PREFIX=deploytest

cleanup() {
  (cd "$work" && docker compose -p deploytest-ci --env-file ci.env down --remove-orphans >/dev/null 2>&1) || true
  docker rm -f deploy-test-registry >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
current_tag() { sed -n 's/^SAMPLE_TAG=//p' "$work/ci.env"; }
container() { (cd "$work" && docker compose -p deploytest-ci --env-file ci.env ps -q sample); }
running_version() { docker exec "$(container)" cat /version; }
container_env() { docker exec "$(container)" printenv "$1" || true; }

docker run -d --name deploy-test-registry -p 5000:5000 registry:3 >/dev/null
for _ in $(seq 30); do curl -fsS http://localhost:5000/v2/ >/dev/null 2>&1 && break; sleep 1; done

for spec in v1:yes v2:yes broken:no; do
  tag="${spec%%:*}"
  docker build -q -t "$image:$tag" --build-arg VERSION="$tag" --build-arg HEALTHY="${spec##*:}" \
    "$repo/examples/deploy-test/image" >/dev/null
  docker push -q "$image:$tag" >/dev/null
done

cp "$repo/servers/deploy.sh" "$repo/examples/deploy-test/docker-compose.yml" "$work/"
printf 'ENV_NAME=ci\n' >"$work/ci.env"

# ---------- image deploys ----------

"$work/deploy.sh" sample v1 ci </dev/null || fail "first deploy"
[[ "$(current_tag)" == v1 && "$(running_version)" == v1 ]] || fail "v1 not running"
pass "first deploy (no previous tag)"

SSH_ORIGINAL_COMMAND="/opt/voidmails/deploy.sh sample v2 ci" "$work/deploy.sh" </dev/null || fail "deploy v2"
[[ "$(current_tag)" == v2 && "$(running_version)" == v2 ]] || fail "v2 not running"
pass "upgrade via SSH forced-command arguments"

if "$work/deploy.sh" sample broken ci </dev/null; then fail "unhealthy deploy reported success"; fi
[[ "$(current_tag)" == v2 ]] || fail "env file not restored (SAMPLE_TAG=$(current_tag))"
[[ "$(running_version)" == v2 ]] || fail "v2 not running after rollback"
pass "unhealthy deploy fails and rolls back to v2"

if "$work/deploy.sh" sample does-not-exist ci </dev/null; then fail "missing tag reported success"; fi
[[ "$(current_tag)" == v2 && "$(running_version)" == v2 ]] || fail "failed pull changed state"
pass "failed pull leaves service untouched"

for bad in "sample;id v1 ci" "sample v1 ../ci" "other v1 ci" "sample v1 nope" "sample v1 ci --config=yaml"; do
  # shellcheck disable=SC2086
  if "$work/deploy.sh" $bad </dev/null 2>/dev/null; then fail "accepted invalid args: $bad"; fi
done
if SSH_ORIGINAL_COMMAND="sample v1 ci; rm -rf /" "$work/deploy.sh" </dev/null 2>/dev/null; then
  fail "accepted injected forced command"
fi
pass "rejects invalid input"

# ---------- SOPS config ----------

age-keygen -o "$work/server.key" 2>/dev/null
age-keygen -o "$work/other.key" 2>/dev/null
export SOPS_AGE_KEY_FILE="$work/server.key"
server_pub="$(age-keygen -y "$work/server.key")"
other_pub="$(age-keygen -y "$work/other.key")"
env_out="$work/env/ci/sample.env"

# bundle <dir> -> gzipped tar of the files in <dir>, like deploy.yml sends it
bundle() { (cd "$1" && tar -czf - ./*); }
encrypt() { sops encrypt --age "$2" --input-type yaml --output-type yaml "$1"; }

mkdir -p "$work/c1" "$work/c2" "$work/c3" "$work/c4" "$work/c5" "$work/c6"
printf 'LOG_LEVEL: debug\nFEATURE_X: true\nWORKERS: 4\n' >"$work/c1/values.yaml"
printf '%s\n' "API_TOKEN: 'p\$ss#w\"rd x'" >"$work/c1/plain.yaml"
encrypt "$work/c1/plain.yaml" "$server_pub,$other_pub" >"$work/c1/secrets.yaml"
rm "$work/c1/plain.yaml"

bundle "$work/c1" | SSH_ORIGINAL_COMMAND="/opt/voidmails/deploy.sh sample v1 ci --config=env" "$work/deploy.sh" ||
  fail "deploy with config"
[[ "$(running_version)" == v1 ]] || fail "v1 not running after config deploy"
[[ "$(container_env API_TOKEN)" == "p\$ss#w\"rd x" ]] || fail "secret not passed literally: $(container_env API_TOKEN)"
[[ "$(container_env LOG_LEVEL)" == debug && "$(container_env FEATURE_X)" == true && "$(container_env WORKERS)" == 4 ]] ||
  fail "values not passed"
[[ "$(stat -c %a "$env_out")" == 600 ]] || fail "env file mode is $(stat -c %a "$env_out")"
cp "$env_out" "$work/good.env"
pass "values + decrypted secrets reach the container literally (env file mode 600)"

printf 'LOG_LEVEL: debug\nBROKEN: "1"\n' >"$work/c2/values.yaml"
cp "$work/c1/secrets.yaml" "$work/c2/"
if bundle "$work/c2" | "$work/deploy.sh" sample v2 ci --config=env; then fail "broken config reported success"; fi
[[ "$(current_tag)" == v1 && "$(running_version)" == v1 ]] || fail "image not rolled back"
cmp -s "$env_out" "$work/good.env" || fail "config not rolled back"
[[ -z "$(container_env BROKEN)" && -n "$(container_env API_TOKEN)" ]] || fail "running container has the broken config"
pass "broken config rolls back image and config together"

printf '%s\n' "API_TOKEN: nope" >"$work/c3/plain.yaml"
encrypt "$work/c3/plain.yaml" "$other_pub" >"$work/c3/secrets.yaml"
rm "$work/c3/plain.yaml"
if bundle "$work/c3" | "$work/deploy.sh" sample v2 ci --config=env 2>/dev/null; then
  fail "accepted secrets it cannot decrypt"
fi
printf 'API_TOKEN: plaintext\n' >"$work/c4/secrets.yaml"
if bundle "$work/c4" | "$work/deploy.sh" sample v2 ci --config=env 2>/dev/null; then fail "accepted plaintext secrets"; fi
printf 'A: 1\n' >"$work/c5/values.yaml"
printf 'x\n' >"$work/c5/evil.sh"
if bundle "$work/c5" | "$work/deploy.sh" sample v2 ci --config=env 2>/dev/null; then fail "accepted unexpected file"; fi
printf 'API_TOKEN: dup\n' >"$work/c6/values.yaml"
cp "$work/c1/secrets.yaml" "$work/c6/"
if bundle "$work/c6" | "$work/deploy.sh" sample v2 ci --config=env 2>/dev/null; then fail "accepted duplicate key"; fi
if echo "not a tarball" | "$work/deploy.sh" sample v2 ci --config=env 2>/dev/null; then fail "accepted garbage bundle"; fi
if [[ "$(current_tag)" != v1 || "$(running_version)" != v1 ]] || ! cmp -s "$env_out" "$work/good.env"; then
  fail "a rejected bundle changed state"
fi
pass "rejects undecryptable, plaintext, duplicate, unexpected and malformed config without changing anything"

mkdir -p "$work/j1"
printf 'environment: ci\napiBaseUrl: https://api.ci.example.com\nfeatures:\n  chat: true\n' >"$work/j1/values.yaml"
bundle "$work/j1" | "$work/deploy.sh" sample v1 ci --config=json || fail "json config deploy"
json_out="$work/config/ci/sample.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["features"]["chat"] is True and d["apiBaseUrl"].startswith("https://")' \
  "$json_out" || fail "json config not rendered"
[[ "$(stat -c %a "$json_out")" == 644 ]] || fail "json config mode is $(stat -c %a "$json_out")"
cp "$work/c1/secrets.yaml" "$work/j1/"
if bundle "$work/j1" | "$work/deploy.sh" sample v1 ci --config=json 2>/dev/null; then fail "json accepted secrets"; fi
pass "json config is rendered public (644) and refuses secrets"

[[ "$(grep -c . "$work/deploy-history.log")" -eq 7 ]] || fail "unexpected history: $(cat "$work/deploy-history.log")"
pass "deploy-history.log written"
echo "all deploy.sh tests passed"

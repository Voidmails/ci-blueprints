#!/usr/bin/env bash
# End-to-end test of servers/deploy.sh against a local registry: deploy, upgrade, failed deploy with
# automatic rollback, forced-command argument parsing and input validation.
#   examples/deploy-test/run-tests.sh   (needs docker; starts a registry on localhost:5000)
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
running_version() {
  local id
  id="$(cd "$work" && docker compose -p deploytest-ci --env-file ci.env ps -q sample)"
  docker exec "$id" cat /version
}

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

"$work/deploy.sh" sample v1 ci || fail "first deploy"
[[ "$(current_tag)" == v1 && "$(running_version)" == v1 ]] || fail "v1 not running"
pass "first deploy (no previous tag)"

SSH_ORIGINAL_COMMAND="/opt/voidmails/deploy.sh sample v2 ci" "$work/deploy.sh" || fail "deploy v2"
[[ "$(current_tag)" == v2 && "$(running_version)" == v2 ]] || fail "v2 not running"
pass "upgrade via SSH forced-command arguments"

if "$work/deploy.sh" sample broken ci; then fail "unhealthy deploy reported success"; fi
[[ "$(current_tag)" == v2 ]] || fail "env file not restored (SAMPLE_TAG=$(current_tag))"
[[ "$(running_version)" == v2 ]] || fail "v2 not running after rollback"
pass "unhealthy deploy fails and rolls back to v2"

if "$work/deploy.sh" sample does-not-exist ci; then fail "missing tag reported success"; fi
[[ "$(current_tag)" == v2 && "$(running_version)" == v2 ]] || fail "failed pull changed state"
pass "failed pull leaves service untouched"

for bad in "sample;id v1 ci" "sample v1 ../ci" "other v1 ci" "sample v1 nope"; do
  # shellcheck disable=SC2086
  if "$work/deploy.sh" $bad 2>/dev/null; then fail "accepted invalid args: $bad"; fi
done
if SSH_ORIGINAL_COMMAND="sample v1 ci; rm -rf /" "$work/deploy.sh" 2>/dev/null; then
  fail "accepted injected forced command"
fi
pass "rejects invalid input"

[[ "$(grep -c . "$work/deploy-history.log")" -eq 4 ]] || fail "unexpected history: $(cat "$work/deploy-history.log")"
pass "deploy-history.log written"
echo "all deploy.sh tests passed"

# ci-blueprints

Reusable GitHub Actions pipelines for the Voidmails services. Each service repo keeps one short
`ci.yml` that calls these blueprints with `@v1`. Images go to GHCR. Deploys go over SSH to one
Hetzner server running Docker Compose behind Caddy.

```
pull request ──► CI (lint/test/build)                     main is protected: CI must pass
push to main ──► docker-publish ──► deploy staging ──► deploy production (waits for approval)
                 ghcr.io/voidmails/<service>:<sha>        healthcheck or automatic rollback
```

## Contents

| Path | What |
|---|---|
| `.github/workflows/node-ci.yml` | CI for Node projects (NestJS backend, React landing page) |
| `.github/workflows/flutter-ci.yml` | CI for Flutter projects (frontend) |
| `.github/workflows/docker-publish.yml` | Build with buildx + GHA cache, push to GHCR |
| `.github/workflows/deploy.yml` | SSH deploy of one service to one environment |
| `.github/workflows/test-templates.yml` | Self-test of this repo |
| `servers/` | `docker-compose.yml`, `Caddyfile`, `deploy.sh`, env templates, [`SETUP.md`](servers/SETUP.md) |
| `examples/consumers/*/ci.yml` | Ready-to-copy workflows for frontend, landing, backend, mailserver |
| `examples/node-backend`, `static-web`, `flutter-web` | Tiny sample projects; their `Dockerfile`s are the templates for the real repos |
| `examples/deploy-test/` | End-to-end test of `deploy.sh`, including rollback |

## Blueprints

### `node-ci.yml`

| Input | Default | |
|---|---|---|
| `node-version` | `24` | |
| `working-directory` | `.` | |
| `install-command` | `npm ci` | |
| `lint-command` | *(empty, skipped)* | |
| `test-command` | `npm test` | empty skips |
| `build-command` | `npm run build` | empty skips |
| `timeout-minutes` | `15` | |

### `flutter-ci.yml`

| Input | Default | |
|---|---|---|
| `flutter-version` | **required** | pin it, e.g. `3.47.8` |
| `working-directory` | `.` | |
| `format-check` / `analyze` | `true` | |
| `test-command` | `flutter test` | empty skips |
| `build-command` | `flutter build web --release` | empty skips |
| `timeout-minutes` | `20` | |

### `docker-publish.yml`

Needs `permissions: contents: read, packages: write` on the calling job. It logs in to GHCR with
`GITHUB_TOKEN`.

| Input | Default | |
|---|---|---|
| `image-name` | **required** | pushed as `ghcr.io/<owner>/<image-name>` |
| `context` | `.` | |
| `dockerfile` | `<context>/Dockerfile` | |
| `build-args` | | newline-separated `KEY=VALUE`, no secrets |
| `platforms` | `linux/amd64` | |
| `push` | `true` | `false` only verifies the build |
| `timeout-minutes` | `30` | |

Tags: `<full commit sha>` always, plus `latest` on the default branch.
Outputs: `image`, `image-tag` (the SHA), `digest`.

### `deploy.yml`

| Input | | |
|---|---|---|
| `service` | **required** | compose service name |
| `image-tag` | **required** | usually `needs.publish.outputs.image-tag` |
| `environment` | **required** | `staging` / `production` (GitHub Environment *and* server env) |
| `deploy-script` | `/opt/voidmails/deploy.sh` | |

Secrets, declared explicitly (no `secrets: inherit`): `DEPLOY_SSH_KEY`, `DEPLOY_HOST`,
`DEPLOY_USER`, `DEPLOY_KNOWN_HOSTS`. The deploy job sets `environment:`, so GitHub resolves them
from that Environment of the calling repo. The consumer passes them through by name.

What it does:

1. Validates the inputs.
2. Opens SSH with `StrictHostKeyChecking=yes` against the pinned `DEPLOY_KNOWN_HOSTS`
   (no `ssh-keyscan`).
3. Runs `deploy.sh <service> <tag> <env>` on the server, which:
   1. sets `<SERVICE>_TAG=<tag>` in `<env>.env`
   2. runs `docker compose pull <service>`
   3. runs `docker compose up -d --no-deps --wait <service>`, so only that service is touched and
      the command waits for its healthcheck
   4. if the service is unhealthy, restores the previous tag, restarts it and **fails the job**

Concurrency is `deploy-<environment>-<service>`, without cancelling, so deploys never overlap. On
the server, `flock` also serializes deploys of different services to the same environment.

## Add a new service in 3 steps

Conventions: service name = image name = compose service. Its tag variable is `<SERVICE>_TAG`
(uppercase, `-` becomes `_`). Its upstream for Caddy is `<env>-<service>`.

1. **In the new repo**: add a `Dockerfile` with a health endpoint (start from one in
   `examples/`). Copy the closest `examples/consumers/*/ci.yml` to `.github/workflows/ci.yml` and
   change `image-name` and `service`. Create the `staging` and `production` Environments with the
   four deploy secrets (see [Required secrets](#required-secrets)).
2. **In this repo**: copy an existing service block in `servers/docker-compose.yml`. Change the
   image (`ghcr.io/voidmails/<service>:${<SERVICE>_TAG:-latest}`), the healthcheck, and the alias
   (`${ENV_NAME}-<service>`). If it is public, add a block to `servers/Caddyfile`. Open a PR;
   `test-templates` validates both files.
3. **On the server**: copy the updated `docker-compose.yml` / `Caddyfile` to `/opt/voidmails`. If
   the Caddyfile changed, restart Caddy ([SETUP.md §7](servers/SETUP.md#7-app-directory-config-and-network)).
   Push to `main` in the new repo, and it deploys.

No new pipeline is needed. If a new stack (say Go) needs its own CI, that is one new
`<stack>-ci.yml` here, released as a minor version.

## Versioning

- Releases are semver tags: `v1.0.0`, `v1.1.0`, ...
- Consumers pin the major tag `@v1`. **`v1` is moved only for non-breaking changes** (new optional
  input, bug fix, action bumps):

  ```bash
  git tag -a v1.2.0 -m "v1.2.0" && git push origin v1.2.0
  git tag -fa v1 -m "v1 -> v1.2.0" && git push -f origin v1
  ```

- **Breaking** changes get `v2.0.0` and a new `v2` tag, and consumers migrate one by one. Breaking
  means: removing or renaming an input, output or secret; making an input required; changing a
  default in a way that changes behavior; changing the image tag scheme; changing what `deploy.sh`
  expects on the server.
- Dependabot opens weekly grouped PRs for the actions used here. Merge them, then release a patch
  version and move `v1`.

## Required GitHub settings

**This repo (`ci-blueprints`)**

- Settings → Actions → General → **Access**: *"Accessible from repositories in the 'Voidmails'
  organization"*. Without it, private/internal repos cannot call these workflows.
- Settings → Actions → General → **Workflow permissions**: *Read repository contents*. Every
  workflow declares what it needs.

**Organization**

- If Actions are restricted to an allow-list, allow `actions/*`, `docker/*` and
  `subosito/flutter-action`.

**Each service repo**

- **Environments** (Settings → Environments):
  - `staging`: deployment branches limited to `main`, with the four deploy secrets.
  - `production`: **required reviewers** and deployment branches limited to `main`, with the same
    four secrets. The `production` job waits for approval.
  - Mailserver repo: `production` only.
- **Branch ruleset on `main`**: require a PR and the CI status check. It shows up as
  `ci / lint, test, build` (Node), `ci / analyze, test, build` (Flutter) or
  `ci / build mailserver`. The CI job runs only on pull requests.
- Workflow permissions: *Read repository contents* (the consumer grants `packages: write` only to
  the publish job).
- GHCR packages are created on the first push, private and linked to the repo. Give the server's
  pull account read access (package settings → Manage access) if it does not already get it from
  the repo.

## Required secrets

| Secret | Where | Value |
|---|---|---|
| `DEPLOY_SSH_KEY` | Environment `staging` and `production` of each service repo | private ed25519 key of the `deploy` user |
| `DEPLOY_HOST` | same | server IP or hostname |
| `DEPLOY_USER` | same | `deploy` |
| `DEPLOY_KNOWN_HOSTS` | same | `<DEPLOY_HOST> ssh-ed25519 AAAA...`, the server's pinned host key |
| `GITHUB_TOKEN` | automatic | GHCR push from `docker-publish.yml` |

On the server (never in GitHub): a GHCR **read-only** PAT used by `docker login`, and runtime
secrets in `/opt/voidmails/env/<env>/<service>.env`. [SETUP.md](servers/SETUP.md) shows how to
create each of them.

## Rollback

**Automatic.** If the new container does not become healthy within 180 s, `deploy.sh` restores the
previous tag and restarts it. The job then fails, so the bad deploy is visible.

**Manual: redeploy an older tag.** Pick the commit SHA you want back.

- **From GitHub**: Actions → `ci` → open the run of that commit → *Re-run jobs* → pick `staging`
  or `production`. A re-run reuses that run's `image-tag` output, and production still asks for
  approval.
- **On the server** (if GitHub is unavailable):

  ```bash
  ssh you@HOST
  sudo -iu deploy
  cd /opt/voidmails
  column -t deploy-history.log | tail -20     # previous tags with their result
  ./deploy.sh backend <older-sha> production
  ```

Then revert the bad commit on `main`; otherwise the next push deploys it again. `latest` is not
used after the first deploy, so a rollback never needs to touch it.

## Testing this repo

`test-templates.yml` runs on every PR and on `main`:

- **lint**: `actionlint` (workflows and consumer examples), `yamllint --strict`, `shellcheck`,
  `docker compose config` for both environments, `caddy validate`.
- **node-ci** against `examples/node-backend` and `examples/static-web`; **flutter-ci** against
  `examples/flutter-web`.
- **docker-publish** (`push: false`) for all three sample Dockerfiles.
- **deploy.sh end-to-end** against a local registry: first deploy, upgrade, unhealthy image with
  automatic rollback, missing tag, forced-command parsing, input validation.
  Run it locally with `examples/deploy-test/run-tests.sh`.

`deploy.yml` itself is only linted, because its SSH hop needs a real server. The script it runs
is tested end to end, and the first deploy to `staging` is the smoke test of the SSH connection.

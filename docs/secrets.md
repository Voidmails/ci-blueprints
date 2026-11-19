# Config and secrets with SOPS

Each service repo keeps its runtime config next to its code:

```
backend/                              (same layout in frontend, landing, mailserver)
├── .sops.yaml                        who can decrypt: the server + every developer's public key
└── deploy/
    ├── staging/
    │   ├── values.yaml               plain text, non-secret      LOG_LEVEL: debug
    │   └── secrets.yaml              encrypted with SOPS         DATABASE_URL: ENC[AES256_GCM,...]
    └── production/
        ├── values.yaml
        └── secrets.yaml
```

**Several services in one repo** (e.g. backend + frontend): each service has its own folder, and
there is one `.sops.yaml` at the repo root:

```
app/
├── .sops.yaml
├── backend/deploy/{staging,production}/{values.yaml,secrets.yaml}
└── frontend/deploy/{staging,production}/values.yaml       public, no secrets
```

The repo's `ci.yml` passes `config-dir: backend/deploy` or `frontend/deploy` to each deploy
(`examples/consumers/app-monorepo/ci.yml`). In the commands below, use the full path, e.g.
`sops backend/deploy/staging/secrets.yaml`.

On every deploy, CI sends `deploy/<env>/` to the server **still encrypted**. The server decrypts
it with its own age key and starts the container with those values. Because config and image come
from the same commit, a rollback restores both together.

| File | Format | Becomes | Secrets allowed? |
|---|---|---|---|
| backend / mailserver `values.yaml` + `secrets.yaml` | flat `KEY: value` | the container's environment variables (`process.env.KEY`) | yes, in `secrets.yaml` only |
| frontend `values.yaml` | any YAML (nested is fine) | `/config.json`, read by the app at startup | **no**: every visitor can read it |

Each developer has their own age key. Every key can decrypt and edit **both** staging and
production.

## 1. Install sops and age (once per developer)

**Windows** (PowerShell):

```powershell
winget install SecretsOPerationS.SOPS
```

```powershell
winget install FiloSottile.age
```

Open a new terminal afterwards, so the commands are on your `PATH`.

**macOS**: `brew install sops age` · **Linux**: `sudo apt install age`, plus the sops `.deb` from
https://github.com/getsops/sops/releases.

Check:

```powershell
sops --version
```

```powershell
age --version
```

## 2. Create your key (once per developer)

**Windows** (sops looks for the key in `%APPDATA%\sops\age\keys.txt`):

```powershell
New-Item -ItemType Directory -Force "$env:APPDATA\sops\age" | Out-Null
```

```powershell
age-keygen -o "$env:APPDATA\sops\age\keys.txt"
```

**macOS / Linux** (the key goes in `~/.config/sops/age/keys.txt`):

```bash
mkdir -p ~/.config/sops/age && age-keygen -o ~/.config/sops/age/keys.txt
```

`age-keygen` prints `Public key: age1...`. Send **only that public key** to someone who already
has access (section 5); never send `keys.txt`. Back up `keys.txt` in your password manager. If
you lose it, someone with access can add a new key for you.

## 3. Pick an editor for sops (once)

`sops <file>` decrypts the file into your editor and re-encrypts it when you save and close.

```powershell
[Environment]::SetEnvironmentVariable("SOPS_EDITOR", "code --wait", "User")
```

Open a new terminal afterwards. Use `notepad` instead of `code --wait` if you don't have VS Code.
On macOS/Linux: `export SOPS_EDITOR="code --wait"` in your shell profile.

## 4. Everyday work

Run every command from the **repo root**, so sops finds `.sops.yaml`.

**Change a non-secret value**: edit `deploy/<env>/values.yaml` like any file.

**Add or change a secret**:

```powershell
sops deploy/staging/secrets.yaml
```

The file opens decrypted. Add or edit a line such as `STRIPE_SECRET_KEY: sk_test_...`, save and
close the editor. sops re-encrypts it. Then commit and open a pull request as usual. The PR diff
shows which keys changed, but not their values.

**Read a secret without editing:**

```powershell
sops decrypt deploy/production/secrets.yaml
```

**Create `secrets.yaml` for a new environment**: run the same `sops deploy/<env>/secrets.yaml`.
sops creates a new file and opens it with example content; replace it with your `KEY: value`
lines.

What happens next:

1. On the PR, CI fails if any `deploy/*/secrets.yaml` (at any depth) is not encrypted. This
   catches an accidentally committed plaintext file before it is merged. If that happened, treat
   the values as leaked and change them.
2. A merge into `dev` deploys `deploy/staging/` to staging. A merge into `main` deploys
   `deploy/production/` to production, after a reviewer approves it. Each deploy sends that
   commit's folder to the server.
3. If the new config breaks the app (for example a secret is missing, so `/health` fails), the
   server rolls back to the previous image **and** the previous config, and the deploy turns red.

Rules:
- Keys must be valid variable names: `DATABASE_URL`, not `database-url`.
- Values are single-line. Quote anything YAML could misread: `'0123'`, `'yes'`, `'on'`.
- A key may be in `values.yaml` or in `secrets.yaml`, not in both.
- Never put real secrets in `values.yaml`, in a frontend repo, or in a `.env` file you commit.
- Use your own local `.env` (in `.gitignore`) for local development, not the staging values.

## 5. Adding a developer (done by anyone who already has a key)

1. The new developer completes sections 1–3 and sends you their public key `age1...`.
2. In **every** service repo, add the key to the `age:` list in `.sops.yaml` (comma-separated,
   one per line), then re-encrypt from the repo root:

   ```powershell
   sops updatekeys -y deploy/staging/secrets.yaml
   ```

   ```powershell
   sops updatekeys -y deploy/production/secrets.yaml
   ```

3. Commit both `.sops.yaml` and the `secrets.yaml` files, then open a PR. Once it is merged, the
   new developer can decrypt.

## 6. Removing a developer

1. Remove their key from `.sops.yaml` in every service repo.
2. Re-encrypt with a fresh data key, so their old copy of the data key stops working:

   ```powershell
   sops updatekeys -y deploy/staging/secrets.yaml
   ```

   ```powershell
   sops rotate -i deploy/staging/secrets.yaml
   ```

   Do the same for `deploy/production/secrets.yaml`.
3. **Change the real secrets** (database passwords, API keys, ...). They could read every value,
   and git history still holds the old encrypted files for their key.

## One-time bootstrap

Done once by the person who sets this up (the first one with sops installed):

1. Get the server's public key from the server admin ([SETUP.md §8b](../servers/SETUP.md#8b-sops-decrypting-the-app-secrets)).
2. Create your own key (sections 1–3).
3. In each service repo:
   1. Copy [`examples/sops/.sops.yaml`](../examples/sops/.sops.yaml) to the repo root and put in
      the server's key and yours.
   2. Create `deploy/staging/values.yaml` and `deploy/production/values.yaml`.
   3. For the backend and mailserver, create the secret files:

      ```powershell
      sops deploy/staging/secrets.yaml
      ```

      ```powershell
      sops deploy/production/secrets.yaml
      ```

   4. Make sure the repo's `.github/workflows/ci.yml` matches the current
      `examples/consumers/<service>/ci.yml` (`app-monorepo` for backend + frontend in one repo).
      Its deploy jobs need `contents: read`, and the frontend needs `config-format: json`.
   5. Commit and open a PR.
4. Add the other developers (section 5).

The landing page has no `deploy/` folder unless it needs runtime config. Without one, the server
keeps whatever config it has.

## Examples

`backend/deploy/production/values.yaml`

```yaml
CORS_ORIGIN: https://app.example.com
LOG_LEVEL: info
```

`backend/deploy/production/secrets.yaml`, as you see it in `sops backend/deploy/production/secrets.yaml`:

```yaml
DATABASE_URL: postgres://voidmails:Xk82!pQz@db.internal:5432/voidmails_prod
JWT_SECRET: 9f3c1a7e5b2d4f6a8c0e1b3d5f7a9c2e
STRIPE_SECRET_KEY: sk_live_51Hx...
```

The same file as stored in git:

```yaml
DATABASE_URL: ENC[AES256_GCM,data:8sKxW1...,iv:...,tag:...,type:str]
JWT_SECRET: ENC[AES256_GCM,data:Qm2pZ9...,iv:...,tag:...,type:str]
STRIPE_SECRET_KEY: ENC[AES256_GCM,data:r7Tn...,iv:...,tag:...,type:str]
sops:
    age:
        - recipient: age1...server
        - recipient: age1...developer-1
    lastmodified: "2026-11-19T14:00:00Z"
    mac: ENC[AES256_GCM,data:...,type:str]
    version: 3.13.3
```

`frontend/deploy/production/values.yaml` (public: served as `/config.json`):

```yaml
environment: production
apiBaseUrl: https://api.example.com
stripePublishableKey: pk_live_51Hx...
```

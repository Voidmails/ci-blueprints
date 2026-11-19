# Server setup (single Hetzner server)

One Linux server runs both environments with Docker Compose behind Caddy. CI reaches it over SSH
as the `deploy` user, whose key can only run `deploy.sh`.

Placeholders used below: `HOST` (server IP or DNS name), `example.com` (your domain),
`you` (your personal admin user). Never commit real values.

## Target layout

```
/opt/voidmails/                     owner deploy:deploy
├── docker-compose.yml              from servers/
├── Caddyfile                       from servers/
├── deploy.sh                       from servers/ (chmod 750)
├── production.env                  from production.env.example (tags, domain; no secrets)
├── staging.env                     from staging.env.example
├── env/production/backend.env      runtime secrets per service (chmod 600, never in git)
├── env/staging/backend.env
├── mail/                           mailserver data/config (production)
└── deploy-history.log              written by deploy.sh
```

Each environment is a separate compose project: `voidmails-production` and `voidmails-staging`.
Caddy runs in the production project and proxies to both through the external network `voidmails-edge`.

## 1. Create the server

- Hetzner Cloud → new server, Ubuntu 24.04 LTS, add **your personal** SSH public key.
- Enable **Backups** (see section 10).
- Attach a **Hetzner Cloud Firewall** (section 5).

## 2. Users

Log in once as root (`ssh root@HOST`):

```bash
apt update && apt full-upgrade -y

# Your personal admin user: sudo, your own key
adduser --gecos "" you            # sets a password; it is only used for sudo
usermod -aG sudo you
install -d -m 700 -o you -g you /home/you/.ssh
install -m 600 -o you -g you /root/.ssh/authorized_keys /home/you/.ssh/authorized_keys

# deploy user: no password, no sudo, only the CI key (section 8)
adduser --disabled-password --gecos "" deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
install -m 600 -o deploy -g deploy /dev/null /home/deploy/.ssh/authorized_keys
```

## 3. SSH: keys only, no root

```bash
cat >/etc/ssh/sshd_config.d/00-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers you deploy
X11Forwarding no
EOF
sshd -t && systemctl reload ssh
```

The `00-` prefix matters: the first value wins, and cloud images ship `50-cloud-init.conf`, which
may enable password login. **Open a second terminal and check `ssh you@HOST` works before you
close the root session.** From now on, work as `you`.

## 4. Docker

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker deploy
```

Membership of the `docker` group is root-equivalent. That is why the deploy key is restricted to
`deploy.sh` (section 8).

## 5. Firewall

Open inbound **22/tcp, 80/tcp, 443/tcp, 443/udp** (HTTP/3), plus the mail ports
**25, 465, 587, 993/tcp**. Close everything else.

1. **Hetzner Cloud Firewall** (Console → Firewalls). This is the real perimeter: Docker writes
   its own iptables rules, so **ports published by containers bypass ufw**.
2. **ufw** as a second layer for host services:

   ```bash
   sudo ufw default deny incoming
   sudo ufw default allow outgoing
   sudo ufw allow 22/tcp
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp
   sudo ufw allow 443/udp
   sudo ufw allow 25,465,587,993/tcp
   sudo ufw enable
   ```

GitHub-hosted runners use changing IP ranges, so port 22 stays open to the world. It is protected
by key-only login. Optionally add `fail2ban`.

## 6. Automatic security updates

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

To let it reboot at night when a kernel update needs it, set these in
`/etc/apt/apt.conf.d/50unattended-upgrades`:
`Unattended-Upgrade::Automatic-Reboot "true";` and
`Unattended-Upgrade::Automatic-Reboot-Time "04:30";`.
Docker packages come from Docker's apt repo and are not covered by the default security origins,
so update them on purpose (`sudo apt upgrade`), ideally right after a snapshot.

## 7. App directory, config and network

From your laptop, in a checkout of `ci-blueprints`:

```bash
scp servers/docker-compose.yml servers/Caddyfile servers/deploy.sh servers/*.env.example you@HOST:/tmp/
```

On the server:

```bash
sudo install -d -o deploy -g deploy -m 750 /opt/voidmails
sudo install -o deploy -g deploy -m 640 /tmp/docker-compose.yml /tmp/Caddyfile /tmp/production.env.example /tmp/staging.env.example /opt/voidmails/
sudo install -o deploy -g deploy -m 750 /tmp/deploy.sh /opt/voidmails/

sudo -iu deploy
cd /opt/voidmails
cp production.env.example production.env   # set BASE_DOMAIN and ACME_EMAIL
cp staging.env.example staging.env
install -d -m 700 env env/production env/staging
# runtime secrets, e.g. env/production/backend.env with DATABASE_URL=..., chmod 600
docker network create voidmails-edge
```

To update the config later, copy the changed files the same way. Then:

- After a `Caddyfile` change: `docker compose -p voidmails-production --env-file production.env restart caddy`
- After a change to a service's compose entry: it is applied on that service's next deploy. To apply
  it now, run `./deploy.sh <service> <current-tag> <env>`.

## 8. Registry login and deploy key

**GHCR read access** (as `deploy`). Create a **classic PAT with only `read:packages`**; a
machine/bot account is preferable. At the time of writing GHCR does not accept fine-grained
tokens. The token's user must be able to read the org's packages.

```bash
sudo -iu deploy
read -rs GHCR_PAT && echo "$GHCR_PAT" | docker login ghcr.io -u <github-user> --password-stdin; unset GHCR_PAT
```

The credential is stored in `/home/deploy/.docker/config.json` (mode 600). Skip this if the
packages are public.

**Deploy key.** Generate it on your laptop, not on the server:

```bash
ssh-keygen -t ed25519 -N "" -C "github-actions-deploy" -f voidmails_deploy
```

Install the public key for `deploy`, restricted to `deploy.sh`. `restrict` turns off port, agent
and X11 forwarding and the PTY. The command CI sends ends up in `SSH_ORIGINAL_COMMAND`, and
`deploy.sh` validates it:

```bash
echo "restrict,command=\"/opt/voidmails/deploy.sh\" $(cat voidmails_deploy.pub)" \
  | ssh you@HOST 'sudo tee /home/deploy/.ssh/authorized_keys >/dev/null'
```

**Pinned host key.** On the server, print the line for `DEPLOY_KNOWN_HOSTS`. Use exactly the
same `HOST` value you put in `DEPLOY_HOST`:

```bash
awk -v h="HOST" '{print h, $1, $2}' /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub   # compare with the fingerprint your laptop showed
```

Put these four values in the `staging` and `production` GitHub Environments of each service repo:

| Secret | Value |
|---|---|
| `DEPLOY_SSH_KEY` | contents of `voidmails_deploy` (the private key) |
| `DEPLOY_HOST` | `HOST` |
| `DEPLOY_USER` | `deploy` |
| `DEPLOY_KNOWN_HOSTS` | output of the `awk` line above |

Then store the private key in your password manager and delete it from the laptop. Test it:

```bash
ssh -i voidmails_deploy deploy@HOST /opt/voidmails/deploy.sh backend latest staging
```

Until the backend image exists in GHCR, this fails with `could not pull`. That error still proves
the key, the forced command and the script work. `ssh -i voidmails_deploy deploy@HOST` without a
command must not give you a shell.

## 9. First start

```bash
sudo -iu deploy
cd /opt/voidmails
docker compose -p voidmails-production --env-file production.env up -d caddy
```

Each service starts on the first push to `main` of its repo, because `deploy.sh` only brings up the
service it deploys. DNS records (A/AAAA) for `example.com`, `www`, `app`, `api`, `mail`, `staging`,
`app.staging` and `api.staging` must point at the server before Caddy can obtain certificates.

## 10. Backups and snapshots

- **Hetzner Backups**: daily, 7 kept, about +20% of the server price. Turn them on.
- **Snapshot** before risky changes (OS release upgrade, Docker major update, compose restructuring).
- Neither one is off-site. Back up off-site (e.g. `restic` to a Hetzner Storage Box) and test a restore:
  `/opt/voidmails/*.env`, `/opt/voidmails/env/`, `/opt/voidmails/mail/`, and the database once the
  backend has one. The `caddy_data` volume is worth keeping too (it avoids Let's Encrypt rate limits).
- Images do not need backups: they are in GHCR.

Disk hygiene (as `deploy`, `crontab -e`). Rollbacks re-pull from GHCR, so pruning old images is safe:

```
17 3 * * 0 docker image prune -af --filter "until=336h" >/dev/null 2>&1
```

## 11. Mailserver notes

The mailserver has its own repo (a thin image `FROM docker-mailserver`), deployed with the same
blueprints. It runs in production only.

- **Outbound port 25 is blocked by default** on new Hetzner Cloud accounts (465 too). You can
  receive mail but not deliver it directly. Request an unblock from Hetzner support (Console → your
  project → Limits / support request). It is usually granted once the first invoice is paid. Until
  then, send through an SMTP relay.
- **PTR / rDNS**: in the Cloud Console set the reverse DNS of the server's IPv4 **and** IPv6 to
  `mail.example.com`. The A/AAAA records of `mail.example.com` must point back to the same
  addresses (forward-confirmed rDNS), or major providers will reject or spam-folder your mail.
- **DNS records**:
  - `MX  example.com → mail.example.com` (priority 10)
  - `TXT example.com "v=spf1 mx -all"` (SPF)
  - DKIM: generate the key with docker-mailserver (`setup config dkim`), then publish the TXT
    record it prints at `mail._domainkey.example.com`
  - `TXT _dmarc.example.com "v=DMARC1; p=none; rua=mailto:dmarc@example.com"`. Move to
    `p=quarantine`/`reject` once the reports look clean.
- **TLS**: Caddy obtains the certificate for `mail.example.com` (its Caddyfile block exists for
  that reason). The mailserver reads it read-only from the `caddy_data` volume. After the first
  renewal, check that the mailserver picked it up; restart the container if it did not.
- **Consider a separate server for mail.** Mail IP reputation is fragile, and you don't want a web
  incident or a blocklisting to affect the other. Mailbox data needs stricter backups. ClamAV and
  Rspamd need several GB of RAM. Mail ports and maintenance windows also differ. Moving it later
  costs no pipeline changes: point the mailserver repo's environment secrets (`DEPLOY_HOST`, ...)
  at the new server and give that server its own `/opt/voidmails` with only the mailserver
  (and Caddy, or certbot, for its certificate).

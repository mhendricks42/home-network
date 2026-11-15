# Forgejo: putting the Git server into use

Assumes go-live (E1–E4) is complete. Forgejo is part of the base server
services: `start.sh server` already runs it, Caddy publishes it as
`https://git.home.foxhound.nexus`, and odin's nightly restic run backs up
`/srv/forgejo`. These steps make it useful: an account, a token, a local mirror
of this repository, and monitoring.

**Role:** GitHub stays the source of truth (you and Claude push there; odin and
the NAS pull from it). Forgejo keeps a **pull mirror** at home: a copy that
works when GitHub or the internet is down, and that restic backs up nightly.

| Fact | Value |
|---|---|
| Container | `forgejo`, `127.0.0.1:3000` on odin (only Caddy reaches it) |
| Data | `/srv/forgejo/data` (repositories, SQLite DB, `gitea/conf/app.ini`) |
| Access | HTTPS only (`DISABLE_SSH`), sign-in required for everything, no self-registration |
| Internet | `OFFLINE_MODE`; it still needs github.com for the mirror (outbound from odin is allowed) |

## 1. Check it's running

On odin, in the repo clone:

```bash
cd ~/home-network
sudo docker compose -f compose.server.yml ps forgejo         # State: running
curl -s -o /dev/null -w '%{http_code}\n' https://git.home.foxhound.nexus/   # 200
```

Not running: `sudo sh scripts/start.sh server https …` (your usual profiles).
`000` or a certificate error: see the runbook's Caddy section.

## 2. Administrator account

Skip if you already made one (the runbook's Forgejo step). Check:

```bash
sudo docker compose -f compose.server.yml exec --user 1000:1000 forgejo \
  forgejo --config /data/gitea/conf/app.ini admin user list --admin
```

Otherwise create it. `admin` is a reserved name, so use your own:

```bash
sudo docker compose -f compose.server.yml exec --user 1000:1000 forgejo \
  forgejo --config /data/gitea/conf/app.ini admin user create \
  --username YOUR_USERNAME --email YOUR_USERNAME@git.home.foxhound.nexus \
  --admin --random-password --must-change-password
```

Save the printed password in Dashlane (item `forgejo`), log in at
`https://git.home.foxhound.nexus`, and set your own. Then turn on **two-factor
authentication** (Settings → Security).

## 3. Access token for Git over HTTPS

Git can't use your password with 2FA on. In Forgejo: **Settings → Applications
→ Generate new token**, name `laptop`, scope **repository: read and write**.
Store it in Dashlane next to the login; Forgejo shows it once.

On an admin device, Git asks for it on the first clone or push (user name =
your Forgejo user, password = the token). On Windows, Git Credential Manager
remembers it; in WSL, point Git at it:

```bash
git config --global credential.helper "/mnt/c/Program\ Files/Git/mingw64/bin/git-credential-manager.exe"
```

## 4. Mirror this repository from GitHub

The GitHub repository is private, so Forgejo needs a **read-only** GitHub token:
GitHub → Settings → Developer settings → **Fine-grained tokens** → Generate:
repository access *Only select repositories* → `home-network`, permission
**Contents: Read-only**, expiry 1 year. Store it in Dashlane (item
`github-forgejo-mirror`) and note the expiry date.

In Forgejo: **+ → New migration → GitHub**:

| Field | Value |
|---|---|
| URL | `https://github.com/mhendricks42/home-network` |
| Access token | the GitHub token |
| This repository will be a mirror | ✔ |
| Visibility | Private |

After the first import: repository **Settings → Mirror settings → interval
`8h`**. **Synchronize now** pulls immediately.

Check from odin:

```bash
git ls-remote https://git.home.foxhound.nexus/YOUR_USERNAME/home-network HEAD
git ls-remote https://github.com/mhendricks42/home-network HEAD     # same commit (after a sync)
```

Repeat for other repositories you want a home copy of (for example
`media-stack`, if you keep it on GitHub).

**Using the mirror when GitHub is down:** on odin or the NAS,
`git pull https://git.home.foxhound.nexus/YOUR_USERNAME/home-network main`
(token as the password). Don't push to the mirror; it's read-only and the next
sync overwrites it.

## 5. Monitoring

In Uptime Kuma (`https://status.home.foxhound.nexus`): **Add monitor →
HTTP(s) – Keyword**, URL `https://git.home.foxhound.nexus/user/login`, keyword
`Forgejo`, interval 300 s. vidar resolves the name through its `/etc/hosts`
line from the runbook's acceptance checks (`git.home.foxhound.nexus` is
already in it).

A mirror that stops syncing (expired GitHub token) shows on the repository's
page as *last synchronised …*; renew the token before the expiry you noted.

## 6. Backup and restore

Covered by odin's nightly restic backup (`/srv`; containers are stopped, so the
SQLite database is consistent). Restore test, once:

```bash
sudo bash -c 'set -a; . /root/.config/restic/env; restic restore latest --target /tmp/restore --include /srv/forgejo/data/gitea/conf'
sudo diff -r /srv/forgejo/data/gitea/conf /tmp/restore/srv/forgejo/data/gitea/conf && echo "restore OK"
sudo rm -r /tmp/restore
```

Full restore onto a rebuilt odin: restore `/srv/forgejo`, run
`sudo chown -R 1000:1000 /srv/forgejo`, then `start.sh server …`.

## 7. Updates

The image is pinned in `compose.server.yml`
(`codeberg.org/forgejo/forgejo:<version>`). Read the release notes for every
version you skip (major versions migrate the database and can't be rolled
back), then:

```bash
sudo systemctl start restic-backup.service        # fresh backup first
# edit the tag in compose.server.yml, commit and push, then on odin:
git pull
sudo docker compose -f compose.server.yml pull forgejo
sudo docker compose -f compose.server.yml up -d forgejo
sudo docker compose -f compose.server.yml logs --tail 30 forgejo   # no migration errors
```

## Not covered here

- **Actions runner (CI):** off by default; see the runbook, *Optional Forgejo
  runner*. It runs jobs inside its own container and can't administer hosts.
- **Ansible deployment and nightly drift checks** from the architecture doc:
  not built yet.
- **Making Forgejo the primary** (push here, mirror to GitHub): changes how the
  repo is worked on; decide that separately.

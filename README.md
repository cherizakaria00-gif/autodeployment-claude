# autodeployment-claude

Deploy to your own server from [Claude Code](https://claude.com/claude-code) without breaking production.

`deploy.sh` ships only the files you changed over SSH. It backs everything up first and rolls back on its own if anything fails. The included Claude Code skill teaches Claude to use it: dry run, ask you, deploy, report.

It's built for the common "no CI, one VPS" setup: a **Laravel / PHP** backend behind PHP-FPM and/or a **Next.js** (or any npm-built) frontend run by **PM2**. Either half is optional.

## Why

Copying files to a server by hand goes wrong in a few predictable ways:

| What goes wrong | What the script does |
| --- | --- |
| A build fails on the server and wipes `.next`, so the site is down | Builds **locally first**. On the server, keeps the previous build aside and restores it if the build fails. PM2 is never restarted on a failed build. |
| PHP changes don't show up because OPcache keeps serving old code | Resets OPcache through the web server after every PHP deploy |
| Someone edited a file on the server, and the deploy erases it | **Drift check**: stops if the server copy differs from both your local file and git `HEAD` |
| A typo returns 500 on every page | `php -l` locally and on the server, then an HTTP health check. Any failure triggers an **automatic rollback**. |
| No way back | Timestamped backup of every file touched. `deploy.sh rollback <id>` restores it. |
| Secrets pushed by mistake | Refuses `.env*` and its own config |
| Migrations run at the wrong time | Uploads migration files but never runs them |

## Install

### As a Claude Code plugin (recommended)

```
/plugin marketplace add cherizakaria00-gif/autodeployment-claude
/plugin install autodeployment-claude@autodeployment-claude
```

Then ask Claude: *"deploy the files I just changed"*.

### By hand

```bash
git clone https://github.com/cherizakaria00-gif/autodeployment-claude
mkdir -p ~/.claude/skills/autodeploy
cp autodeployment-claude/skills/autodeploy/SKILL.md autodeployment-claude/deploy.sh ~/.claude/skills/autodeploy/
```

The script also works on its own, without Claude: `bash deploy.sh --help`.

## Set up a project

1. Make sure you can SSH into your server with a key: `ssh user@host true`.
2. Copy `autodeploy.conf.example` to `.autodeploy.conf` at your project root and fill it in.
3. Add `.autodeploy.conf` to your `.gitignore`.

```bash
SSH_HOST="deploy@203.0.113.10"
REMOTE_ROOT="/var/www/myapp"
BACKEND_DIR="backend"        # empty if no PHP backend
FRONTEND_DIR="frontend"      # empty if no frontend
PM2_APP="myapp-web"
HEALTH_HOST="example.com"
HEALTH_PATHS="/ /login"
```

The server must have the same folder layout as your local repository under `REMOTE_ROOT`.

## Use

```bash
bash deploy.sh --dry-run frontend/src/app/page.tsx backend/app/Http/Controllers/HomeController.php
bash deploy.sh frontend/src/app/page.tsx backend/app/Http/Controllers/HomeController.php
bash deploy.sh --changed            # everything changed vs git HEAD, plus untracked files
bash deploy.sh list                 # backups on the server
bash deploy.sh rollback 20261113_101500
bash deploy.sh drift backend/routes/api.php   # what exists only on the server
```

| Option | Effect |
| --- | --- |
| `--dry-run` | Local checks and plan only. Nothing on the server changes. |
| `--yes` | No confirmation prompt (Claude uses this after asking you in chat) |
| `--force` | Deploy despite a drift warning. Only after merging the server changes. |
| `--config FILE` | Use another config file |

## What happens on a deploy

1. **Local checks**: `php -l` on PHP files, then a local frontend build. If either fails, nothing is sent.
2. **Drift check** against the server.
3. **Backup** to `~/autodeploy-backups/<id>/` on the server.
4. **Upload**: each file is written to a temp file, then moved into place.
5. **Backend**: `php -l` on the server, then `config:cache` / `route:cache` when `config/` or `routes/` changed, then an OPcache reset.
6. **Frontend**: build on the server with the old build kept aside, then `pm2 restart`.
7. **Health check** on each `HEALTH_PATHS` entry through your web server, with your domain as Host.
8. Any failure in steps 4–7 restores the files and the previous build, and resets caches.

## Requirements

- Local: `bash`, `ssh`, `git` (for the drift check); `php` and `npm` if you use those halves.
- Server: `bash`, `tar`, `curl`, `sha256sum`; `php` / `npm` / `pm2` as used.
- Tested on macOS (bash 3.2) and Linux.

## Limits

- It deploys files, not whole releases. It isn't a replacement for real CI/CD or blue-green deploys.
- The OPcache reset goes through a temporary PHP file with a random name. The file is deleted right after. If your server forbids running PHP files in `public/` other than `index.php`, set `OPCACHE_RESET=0` and reload PHP-FPM yourself.
- Uploaded files take the SSH user's ownership and default permissions.

## License

MIT

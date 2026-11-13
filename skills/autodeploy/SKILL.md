---
name: autodeploy
description: Deploy changed files to the user's own server over SSH, safely — local checks first, server backup, drift check, Laravel cache + OPcache reset, frontend build with the previous build kept, PM2 restart, health check and automatic rollback. Use when the user asks to deploy, push to production/the server, ship a change, or roll back a deploy, in a project that has (or should have) a .autodeploy.conf.
---

# Autodeploy

Deploys files to the user's server with `deploy.sh` from this plugin. The script
lives next to this skill's plugin root: `${CLAUDE_PLUGIN_ROOT}/deploy.sh`. If that
variable is empty (skill copied by hand), look for `deploy.sh` in
`~/.claude/skills/autodeploy/` or at the project root.

## Before the first deploy in a project

1. Look for `.autodeploy.conf` at the project root. If it's missing, copy
   `autodeploy.conf.example` there and fill it in **with the user**: SSH host,
   remote path, backend/frontend folders, PM2 app name and their domain. Never guess
   a host or path. Ask.
2. Make sure `.autodeploy.conf` is in `.gitignore`.
3. Check that SSH works: `ssh -o BatchMode=yes <SSH_HOST> true`.

## Deploying

1. Decide exactly which files to deploy: only the ones you changed for this task.
   Prefer naming files over `--changed`. `--changed` also picks up unrelated
   work-in-progress.
2. Run a dry run first and read its output:
   `bash deploy.sh --dry-run <files...>`
3. Tell the user what will be deployed and to which server, and get a yes. Deploying
   to production changes a live site. Approval for one deploy does not cover the
   next one.
4. Deploy: `bash deploy.sh --yes <files...>`
5. Report the result plainly: deployed or rolled back, the backup id, and the
   health-check results.

## Rules

- **Drift stop** ("server copy differs from both your local file and git HEAD"):
  someone changed the server directly. Never answer with `--force` on your own.
  Run `deploy.sh drift <file>`, show the user the server-only lines, merge them
  into the local file, then deploy again.
- **Migrations** are uploaded but never run by the script. Tell the user to run them
  at a quiet time. Don't run them yourself unless they ask.
- **Never** deploy `.env` files or `.autodeploy.conf` (the script refuses), and never
  print secrets from the server.
- **If a deploy fails**, the script has already rolled back. Say so, show the error,
  fix the cause locally and dry-run again.
- **To undo a deploy**: `bash deploy.sh list`, then
  `bash deploy.sh rollback <backup-id> --yes` after the user confirms.
- Don't run `pm2 restart` or a server build by hand outside the script. A failed
  build run by hand can wipe the live build and take the site down.

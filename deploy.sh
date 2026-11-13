#!/usr/bin/env bash
#
# autodeployment-claude — safe, file-level deploys to your own server over SSH.
#
# Built for setups without CI: a Laravel/PHP backend and/or a Next.js (or any
# npm-built) frontend run by PM2 on a single VPS. It deploys only the files you
# name, and refuses to leave the site down:
#
#   1. local checks first (php -l, local build) — nothing is sent if they fail
#   2. drift check — refuses to overwrite server-only changes not in git
#   3. timestamped backup of every file it touches, on the server
#   4. upload, remote php -l, Laravel config/route cache, OPcache reset
#   5. frontend build with the previous build kept aside — a failed build
#      restores it and never restarts PM2
#   6. HTTP health check — any failure rolls everything back automatically
#
# Usage:
#   deploy.sh [options] <file> [file ...]   deploy these files
#   deploy.sh [options] --changed           deploy files changed in git (vs HEAD + untracked)
#   deploy.sh list                          list backups on the server
#   deploy.sh rollback <backup-id>          restore a backup
#   deploy.sh drift <file> [file ...]       show server vs local differences
#
# Options:
#   --dry-run    run local checks and print the plan, change nothing
#   --yes        don't ask for confirmation
#   --force      deploy even if the server has changes that aren't in git
#   --config F   config file (default: ./.autodeploy.conf)
#
# Configuration lives in .autodeploy.conf at your project root (see
# autodeploy.conf.example). Never commit it if it holds anything private.

set -euo pipefail

VERSION="1.0.0"

# ─── Output helpers ──────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_DIM=""; C_RST=""
fi
step() { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s ok%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s !!%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%sERR%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
q()    { printf '%q' "$1"; }   # quote one value for the remote shell

# ─── Arguments ───────────────────────────────────────────────────────────────
CONFIG_FILE=".autodeploy.conf"
DRY_RUN=0; ASSUME_YES=0; FORCE=0; USE_CHANGED=0
COMMAND="deploy"
FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --force)   FORCE=1 ;;
    --changed) USE_CHANGED=1 ;;
    --config)  shift; CONFIG_FILE="${1:-}" ;;
    --version) echo "autodeployment-claude $VERSION"; exit 0 ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    list|rollback|drift)
      if [[ ${#FILES[@]} -eq 0 && "$COMMAND" == "deploy" ]]; then COMMAND="$1"; else FILES+=("$1"); fi ;;
    -*) die "Unknown option: $1" ;;
    *)  FILES+=("$1") ;;
  esac
  shift
done

# ─── Configuration ───────────────────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE (copy autodeploy.conf.example to .autodeploy.conf and fill it in)"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${SSH_HOST:?SSH_HOST is required (user@host)}"
: "${REMOTE_ROOT:?REMOTE_ROOT is required (project root on the server)}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
BACKEND_DIR="${BACKEND_DIR:-}"            # e.g. backend   (empty = no backend)
FRONTEND_DIR="${FRONTEND_DIR:-}"          # e.g. frontend  (empty = no frontend)
PHP_BIN="${PHP_BIN:-php}"
BUILD_CMD="${BUILD_CMD:-npm run build}"
BUILD_OUTPUT_DIR="${BUILD_OUTPUT_DIR:-.next}"
LOCAL_BUILD="${LOCAL_BUILD:-1}"
PM2_APP="${PM2_APP:-}"
HEALTH_HOST="${HEALTH_HOST:-}"            # e.g. example.com (sent as Host header)
HEALTH_BASE="${HEALTH_BASE:-https://127.0.0.1}"
HEALTH_PATHS="${HEALTH_PATHS:-/}"
OPCACHE_RESET="${OPCACHE_RESET:-1}"
BACKUP_ROOT="${BACKUP_ROOT:-~/autodeploy-backups}"

SSH_OPTS=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15)
SCP_OPTS=(-P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15 -q)
if [[ -n "$SSH_KEY" ]]; then SSH_OPTS+=(-i "$SSH_KEY"); SCP_OPTS+=(-i "$SSH_KEY"); fi

remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"; }

# Backups use the remote user's home; resolve "~" on the server once.
resolve_backup_root() {
  BACKUP_ROOT_ABS="$(remote "eval echo $BACKUP_ROOT")"
  [[ -n "$BACKUP_ROOT_ABS" ]] || die "Could not resolve BACKUP_ROOT on the server"
}

sha256_of() {   # stdin → hex digest (macOS has shasum, Linux has sha256sum)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

in_dir() { [[ -n "$2" && ( "$1" == "$2/"* ) ]]; }

health_check() {
  [[ -n "$HEALTH_HOST" ]] || { warn "HEALTH_HOST not set — skipping health check"; return 0; }
  local failed=0 path code
  for path in $HEALTH_PATHS; do
    code="$(remote "curl -sk -o /dev/null -w '%{http_code}' --max-time 20 -H $(q "Host: $HEALTH_HOST") $(q "$HEALTH_BASE$path")" || echo 000)"
    if [[ "$code" =~ ^[23] ]]; then ok "health $path → $code"; else warn "health $path → $code"; failed=1; fi
  done
  return $failed
}

opcache_reset() {
  [[ "$OPCACHE_RESET" == "1" && -n "$BACKEND_DIR" && -n "$HEALTH_HOST" ]] || return 0
  local name="_autodeploy_opreset_$RANDOM$RANDOM.php"
  local pub="$REMOTE_ROOT/$BACKEND_DIR/public"
  # A throwaway script under a random name, hit through the web server (the
  # CLI has its own OPcache), then deleted. Hit several times so each PHP-FPM
  # worker that serves a request gets reset.
  remote "set -e; f=$(q "$pub/$name"); trap 'rm -f \"\$f\"' EXIT;
    printf '%s' '<?php echo function_exists(\"opcache_reset\") && opcache_reset() ? \"reset\" : \"none\";' > \"\$f\";
    for i in 1 2 3 4; do curl -sk --max-time 10 -H $(q "Host: $HEALTH_HOST") $(q "$HEALTH_BASE/$name") >/dev/null || true; done" \
    && ok "OPcache reset" || warn "OPcache reset failed — PHP may serve old code until PHP-FPM restarts"
}

frontend_build_and_restart() {
  local web="$REMOTE_ROOT/$FRONTEND_DIR"
  step "Building frontend on the server (previous build kept aside)"
  if ! remote "set -e; cd $(q "$web");
      rm -rf $(q "$BUILD_OUTPUT_DIR.autodeploy-prev");
      if [ -d $(q "$BUILD_OUTPUT_DIR") ]; then cp -a $(q "$BUILD_OUTPUT_DIR") $(q "$BUILD_OUTPUT_DIR.autodeploy-prev"); fi;
      $BUILD_CMD > /tmp/autodeploy-build.log 2>&1 || { tail -30 /tmp/autodeploy-build.log; exit 1; }"; then
    warn "Remote build failed — restoring the previous build (PM2 not restarted)"
    remote "cd $(q "$web") && if [ -d $(q "$BUILD_OUTPUT_DIR.autodeploy-prev") ]; then rm -rf $(q "$BUILD_OUTPUT_DIR") && mv $(q "$BUILD_OUTPUT_DIR.autodeploy-prev") $(q "$BUILD_OUTPUT_DIR"); fi" || true
    return 1
  fi
  ok "build succeeded"
  if [[ -n "$PM2_APP" ]]; then
    remote "pm2 restart $(q "$PM2_APP") --update-env >/dev/null && sleep 5" && ok "PM2 restarted: $PM2_APP"
  fi
}

# ─── list / rollback / drift ─────────────────────────────────────────────────
cmd_list() {
  resolve_backup_root
  remote "cd $(q "$BACKUP_ROOT_ABS") 2>/dev/null && ls -1td -- */ 2>/dev/null | sed 's#/\$##' | head -20 | while read -r d; do echo \"\$d  \$(cat $(q "$BACKUP_ROOT_ABS")/\$d/files.txt 2>/dev/null | wc -l | tr -d ' ') file(s)\"; done"
}

restore_backup() {   # $1 = backup dir (absolute, on server)
  local dir="$1"
  remote "set -e; cd $(q "$REMOTE_ROOT");
    if [ -s $(q "$dir/files.tgz") ]; then tar xzf $(q "$dir/files.tgz"); fi;
    if [ -f $(q "$dir/new-files.txt") ]; then while IFS= read -r f; do if [ -n \"\$f\" ]; then rm -f -- \"\$f\"; fi; done < $(q "$dir/new-files.txt"); fi"
}

cmd_rollback() {
  [[ ${#FILES[@]} -eq 1 ]] || die "Usage: deploy.sh rollback <backup-id>   (see: deploy.sh list)"
  resolve_backup_root
  local dir="$BACKUP_ROOT_ABS/${FILES[0]}"
  remote "test -f $(q "$dir/files.txt")" || die "Backup not found: ${FILES[0]}"
  local touched; touched="$(remote "cat $(q "$dir/files.txt")")"
  echo "$touched" | sed 's/^/   /'
  if [[ $ASSUME_YES -ne 1 ]]; then read -r -p "Restore these files from ${FILES[0]}? [y/N] " a; [[ "$a" =~ ^[yY] ]] || exit 1; fi
  step "Restoring backup ${FILES[0]}"
  restore_backup "$dir"
  ok "files restored"
  if echo "$touched" | grep -q '\.php$'; then opcache_reset; fi
  if [[ -n "$FRONTEND_DIR" ]] && echo "$touched" | grep -q "^$FRONTEND_DIR/"; then frontend_build_and_restart || die "Rebuild after rollback failed — check the server"; fi
  health_check || die "Health check failed after rollback — check the server now"
  ok "rollback complete"
}

cmd_drift() {
  [[ ${#FILES[@]} -gt 0 ]] || die "Usage: deploy.sh drift <file> [file ...]"
  local f tmp; tmp="$(mktemp)"
  for f in "${FILES[@]}"; do
    if remote "cat $(q "$REMOTE_ROOT/$f")" > "$tmp" 2>/dev/null; then
      echo "── $f (lines starting with < exist only on the server)"
      diff "$tmp" "$f" || true
    else
      echo "── $f: not on the server (new file)"
    fi
  done
  rm -f "$tmp"
}

case "$COMMAND" in
  list)     cmd_list; exit 0 ;;
  rollback) cmd_rollback; exit 0 ;;
  drift)    cmd_drift; exit 0 ;;
esac

# ─── deploy: collect files ───────────────────────────────────────────────────
if [[ $USE_CHANGED -eq 1 ]]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "--changed needs a git repository"
  while IFS= read -r f; do [[ -n "$f" && -f "$f" ]] && FILES+=("$f"); done < <(
    { git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u)
fi
[[ ${#FILES[@]} -gt 0 ]] || die "Nothing to deploy. Pass files, or --changed."

PHP_FILES=(); FRONT_FILES=(); MIGRATIONS=(); CONFIG_CHANGED=0; ROUTES_CHANGED=0
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || die "Local file not found: $f"
  case "$f" in /*|*..*) die "Use paths relative to the project root, without '..': $f" ;; esac
  case "$f" in
    .autodeploy.conf|*.env|*/.env|.env.*|*/.env.*) die "Refusing to deploy secrets/config file: $f" ;;
  esac
  [[ "$f" == *.php ]] && PHP_FILES+=("$f")
  if in_dir "$f" "$BACKEND_DIR"; then
    in_dir "$f" "$BACKEND_DIR/config" && CONFIG_CHANGED=1
    in_dir "$f" "$BACKEND_DIR/routes" && ROUTES_CHANGED=1
    in_dir "$f" "$BACKEND_DIR/database/migrations" && MIGRATIONS+=("$f")
  fi
  in_dir "$f" "$FRONTEND_DIR" && FRONT_FILES+=("$f")
done

echo
echo "autodeployment-claude $VERSION → $SSH_HOST:$REMOTE_ROOT"
printf '   %s\n' "${FILES[@]}"
echo

# ─── 1. Local checks ─────────────────────────────────────────────────────────
if [[ ${#PHP_FILES[@]} -gt 0 ]]; then
  if command -v "$PHP_BIN" >/dev/null 2>&1; then
    step "php -l (local)"
    for f in "${PHP_FILES[@]}"; do "$PHP_BIN" -l "$f" >/dev/null || die "PHP syntax error in $f"; done
    ok "${#PHP_FILES[@]} PHP file(s) clean"
  else
    warn "PHP not installed locally — syntax will only be checked on the server"
  fi
fi

if [[ ${#FRONT_FILES[@]} -gt 0 && "$LOCAL_BUILD" == "1" ]]; then
  step "Local build in $FRONTEND_DIR (catches errors before the server is touched)"
  ( cd "$FRONTEND_DIR" && $BUILD_CMD > /tmp/autodeploy-local-build.log 2>&1 ) \
    || { tail -30 /tmp/autodeploy-local-build.log; die "Local build failed — nothing was deployed"; }
  ok "local build succeeded"
fi

# ─── 2. Drift check ──────────────────────────────────────────────────────────
step "Checking the server for changes that aren't in git"
resolve_backup_root
DRIFTED=()
NEW_FILES=()
# Hashes of what this script itself last deployed — a server file matching one
# of these isn't someone's manual edit, even if it was never committed.
KNOWN_SUMS="$(remote "cat $(q "$BACKUP_ROOT_ABS/deployed.sha256") 2>/dev/null" || true)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  for f in "${FILES[@]}"; do
    remote_sum="$(remote "sha256sum $(q "$REMOTE_ROOT/$f") 2>/dev/null | cut -d' ' -f1" || true)"
    if [[ -z "$remote_sum" ]]; then NEW_FILES+=("$f"); continue; fi
    local_sum="$(sha256_of < "$f")"
    [[ "$remote_sum" == "$local_sum" ]] && continue
    printf '%s\n' "$KNOWN_SUMS" | grep -qxF "$remote_sum  $f" && continue
    head_sum="$(git show "HEAD:$f" 2>/dev/null | sha256_of || true)"
    if ! git cat-file -e "HEAD:$f" 2>/dev/null || [[ "$remote_sum" != "$head_sum" ]]; then DRIFTED+=("$f"); fi
  done
else
  for f in "${FILES[@]}"; do remote "test -f $(q "$REMOTE_ROOT/$f")" || NEW_FILES+=("$f"); done
  warn "Not a git repository — drift check skipped"
fi
if [[ ${#DRIFTED[@]} -gt 0 ]]; then
  warn "The server copy of these files differs from both your local file and git HEAD:"
  printf '     %s\n' "${DRIFTED[@]}" >&2
  warn "Someone changed them directly on the server. Run: deploy.sh drift <file>"
  [[ $FORCE -eq 1 ]] || die "Stopped to avoid overwriting server-only changes (use --force once you've merged them)"
  warn "--force given — overwriting"
else
  ok "no server-only changes"
fi

# ─── Plan ────────────────────────────────────────────────────────────────────
echo
echo "Plan:"
echo "   backup ${#FILES[@]} file(s), upload, then:"
[[ ${#PHP_FILES[@]} -gt 0 ]] && echo "   - php -l on the server, OPcache reset"
[[ $CONFIG_CHANGED -eq 1 ]] && echo "   - php artisan config:cache"
[[ $ROUTES_CHANGED -eq 1 ]] && echo "   - php artisan route:cache"
[[ ${#FRONT_FILES[@]} -gt 0 ]] && echo "   - frontend build on the server${PM2_APP:+, pm2 restart $PM2_APP}"
echo "   - health check: ${HEALTH_HOST:-<skipped>} $HEALTH_PATHS"
if [[ ${#MIGRATIONS[@]} -gt 0 ]]; then
  warn "Migration file(s) included. They are uploaded but NOT run — run them yourself at a quiet time."
fi
echo

if [[ $DRY_RUN -eq 1 ]]; then ok "dry run — nothing changed"; exit 0; fi
if [[ $ASSUME_YES -ne 1 ]]; then
  read -r -p "Deploy to $SSH_HOST? [y/N] " answer
  [[ "$answer" =~ ^[yY] ]] || die "Cancelled"
fi

# ─── 3. Backup ───────────────────────────────────────────────────────────────
BACKUP_ID="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT_ABS/$BACKUP_ID"
step "Backup → $BACKUP_DIR"
EXISTING=()
for f in "${FILES[@]}"; do
  skip=0; for n in ${NEW_FILES[@]+"${NEW_FILES[@]}"}; do [[ "$n" == "$f" ]] && skip=1; done
  [[ $skip -eq 0 ]] && EXISTING+=("$f")
done
remote "mkdir -p $(q "$BACKUP_DIR")"
printf '%s\n' "${FILES[@]}" | remote "cat > $(q "$BACKUP_DIR/files.txt")"
if [[ ${#NEW_FILES[@]} -gt 0 ]]; then printf '%s\n' "${NEW_FILES[@]}"; fi | remote "cat > $(q "$BACKUP_DIR/new-files.txt")"
if [[ ${#EXISTING[@]} -gt 0 ]]; then
  args=""; for f in "${EXISTING[@]}"; do args+=" $(q "$f")"; done
  remote "cd $(q "$REMOTE_ROOT") && tar czf $(q "$BACKUP_DIR/files.tgz") $args"
fi
ok "backup id: $BACKUP_ID"

rollback_now() {
  warn "Rolling back to $BACKUP_ID"
  restore_backup "$BACKUP_DIR" || warn "file restore failed — restore manually from $BACKUP_DIR"
  [[ ${#PHP_FILES[@]} -gt 0 ]] && opcache_reset
  if [[ $CONFIG_CHANGED -eq 1 ]]; then remote "cd $(q "$REMOTE_ROOT/$BACKEND_DIR") && $PHP_BIN artisan config:cache >/dev/null" || true; fi
  if [[ $ROUTES_CHANGED -eq 1 ]]; then remote "cd $(q "$REMOTE_ROOT/$BACKEND_DIR") && $PHP_BIN artisan route:cache >/dev/null" || true; fi
}

# ─── 4. Upload ───────────────────────────────────────────────────────────────
step "Uploading"
for f in "${FILES[@]}"; do
  # Write to a temp file then move into place, so a half-written file is never served.
  remote "mkdir -p $(q "$(dirname "$REMOTE_ROOT/$f")") && cat > $(q "$REMOTE_ROOT/$f.autodeploy-tmp") && mv -f $(q "$REMOTE_ROOT/$f.autodeploy-tmp") $(q "$REMOTE_ROOT/$f")" < "$f" \
    || { rollback_now; die "Upload failed for $f — rolled back"; }
done
ok "${#FILES[@]} file(s) uploaded"
# Remember what we deployed (see the drift check). Keeps the latest hash per file.
{ for f in "${FILES[@]}"; do printf '%s  %s\n' "$(sha256_of < "$f")" "$f"; done; } \
  | remote "touch $(q "$BACKUP_ROOT_ABS/deployed.sha256"); cat - $(q "$BACKUP_ROOT_ABS/deployed.sha256") | awk '{k=substr(\$0,67)} !seen[k]++' > $(q "$BACKUP_ROOT_ABS/deployed.sha256.tmp") && mv $(q "$BACKUP_ROOT_ABS/deployed.sha256.tmp") $(q "$BACKUP_ROOT_ABS/deployed.sha256")" || true

# ─── 5. Backend ──────────────────────────────────────────────────────────────
if [[ ${#PHP_FILES[@]} -gt 0 ]]; then
  step "php -l (server)"
  for f in "${PHP_FILES[@]}"; do
    remote "$PHP_BIN -l $(q "$REMOTE_ROOT/$f") >/dev/null" || { rollback_now; die "PHP syntax error on the server in $f — rolled back"; }
  done
  ok "clean"
fi
if [[ $CONFIG_CHANGED -eq 1 ]]; then
  step "config:cache"; remote "cd $(q "$REMOTE_ROOT/$BACKEND_DIR") && $PHP_BIN artisan config:cache >/dev/null" || { rollback_now; die "config:cache failed — rolled back"; }
fi
if [[ $ROUTES_CHANGED -eq 1 ]]; then
  step "route:cache"; remote "cd $(q "$REMOTE_ROOT/$BACKEND_DIR") && $PHP_BIN artisan route:cache >/dev/null" || { rollback_now; die "route:cache failed — rolled back"; }
fi
[[ ${#PHP_FILES[@]} -gt 0 || $CONFIG_CHANGED -eq 1 ]] && opcache_reset

# ─── 6. Frontend ─────────────────────────────────────────────────────────────
if [[ ${#FRONT_FILES[@]} -gt 0 ]]; then
  if ! frontend_build_and_restart; then
    rollback_now
    die "Server build failed — files rolled back, previous build restored, PM2 untouched"
  fi
fi

# ─── 7. Health check ─────────────────────────────────────────────────────────
step "Health check"
if ! health_check; then
  rollback_now
  [[ ${#FRONT_FILES[@]} -gt 0 ]] && { frontend_build_and_restart || warn "rebuild after rollback failed — check the server"; }
  health_check || warn "Still unhealthy after rollback — check the server now"
  die "Health check failed — deploy rolled back"
fi

[[ ${#FRONT_FILES[@]} -gt 0 ]] && remote "rm -rf $(q "$REMOTE_ROOT/$FRONTEND_DIR/$BUILD_OUTPUT_DIR.autodeploy-prev")" || true

echo
ok "Deployed ${#FILES[@]} file(s). Backup id: $BACKUP_ID"
echo "   ${C_DIM}undo with: deploy.sh rollback $BACKUP_ID${C_RST}"

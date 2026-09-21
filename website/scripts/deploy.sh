#!/usr/bin/env bash
# Deploy website/ over SSH using an existing host alias from ~/.ssh/config.
# Does not embed keys, passwords, or tokens.
#
# Required:
#   YINWEI_SSH_HOST     SSH config Host alias
#   YINWEI_REMOTE_ROOT  Absolute document root on the server
#
# Optional:
#   YINWEI_SSH_PORT     default 22
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${YINWEI_SSH_HOST:-}"
REMOTE_ROOT="${YINWEI_REMOTE_ROOT:-}"
PORT="${YINWEI_SSH_PORT:-22}"

if [[ -z "$HOST" || -z "$REMOTE_ROOT" ]]; then
  echo "Refusing to guess a server." >&2
  echo "Set YINWEI_SSH_HOST (ssh config alias) and YINWEI_REMOTE_ROOT." >&2
  echo "This checkout has no ~/.ssh/config host to infer." >&2
  exit 2
fi

if [[ "$REMOTE_ROOT" != /* ]]; then
  echo "YINWEI_REMOTE_ROOT must be an absolute path." >&2
  exit 2
fi

"$ROOT/scripts/fetch-android-apk.sh"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${REMOTE_ROOT}-backup-${STAMP}"
SSH=(ssh -p "$PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$HOST")

echo "Inspecting remote host alias: $HOST"
"${SSH[@]}" 'set -e; echo "user=$(id -un)"; echo "pwd=$(pwd)"; if command -v nginx >/dev/null; then echo "web=nginx"; nginx -t 2>/dev/null || true; elif command -v caddy >/dev/null; then echo "web=caddy"; elif command -v apache2ctl >/dev/null; then echo "web=apache"; else echo "web=unknown"; fi'

echo "Backing up $REMOTE_ROOT -> $BACKUP (if the root exists)"
"${SSH[@]}" "set -e
if [ -d '$REMOTE_ROOT' ]; then
  sudo mkdir -p '$(dirname "$BACKUP")'
  sudo cp -a '$REMOTE_ROOT' '$BACKUP'
  echo "BACKUP=$BACKUP"
else
  sudo mkdir -p '$REMOTE_ROOT'
  echo "BACKUP=none (created $REMOTE_ROOT)"
fi
"

echo "Rsync to $HOST:$REMOTE_ROOT"
rsync -av --delete \
  -e "ssh -p $PORT -o BatchMode=yes" \
  --exclude '.git/' \
  --exclude 'scripts/' \
  --exclude '.gitignore' \
  --exclude 'README.md' \
  "$ROOT"/ "$HOST:$REMOTE_ROOT"/

echo "Permissions"
"${SSH[@]}" "sudo find '$REMOTE_ROOT' -type d -exec chmod 755 {} \;
sudo find '$REMOTE_ROOT' -type f -exec chmod 644 {} \;
if command -v nginx >/dev/null; then sudo nginx -t && sudo nginx -s reload; fi
"

echo "Deployed to $HOST:$REMOTE_ROOT"
echo "Previous tree backup: $BACKUP"
